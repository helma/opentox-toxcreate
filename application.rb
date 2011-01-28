['rubygems', "haml", "sass", "rack-flash"].each do |lib|
  require lib
end
gem "opentox-ruby", "~> 0"
require 'opentox-ruby'
gem 'sinatra-static-assets'
require 'sinatra/static_assets'
require 'ftools'
require File.join(File.dirname(__FILE__),'model.rb')
require File.join(File.dirname(__FILE__),'helper.rb')
#require File.join(File.dirname(__FILE__),'parser.rb')

use Rack::Session::Cookie, :expire_after => 28800, 
                           :secret => "ui6vaiNi-change_me"
use Rack::Flash

helpers do 

  def error(message)
    @model.error_messages = message
    LOGGER.error message
    @model.status = "Error"
    @model.save
    #@dataset.delete
    flash[:notice] = message
    redirect url_for('/create')
  end

end

before do
  #unless env['REQUEST_METHOD'] == "GET" or ( env['REQUEST_URI'] =~ /\/login$/ and env['REQUEST_METHOD'] == "POST" ) or !AA_SERVER
    if !logged_in and !( env['REQUEST_URI'] =~ /\/login$/ and env['REQUEST_METHOD'] == "POST" ) #or !AA_SERVER
      login("guest","guest")
      #flash[:notice] = "You have to login first to do this."
      #redirect url_for('/login')
    end
  #end
end

get '/?' do
  redirect url_for('/create')
end

get '/login' do
  haml :login
end

get '/models/?' do
  @models = ToxCreateModel.all(:order => [ :created_at.desc ])
  #@models.each { |model| model.process }
  haml :models
end

get '/model/:id/status/?' do
  response['Content-Type'] = 'text/plain'
  model = ToxCreateModel.get(params[:id])
  begin
    haml :model_status, :locals=>{:model=>model}, :layout => false
  rescue
    return "unavailable"
  end
end

get '/model/:id/:view/?' do
  response['Content-Type'] = 'text/plain'
  model = ToxCreateModel.get(params[:id])

  begin
    #model.process
    #model.save
    case params[:view]
      when "model"
        haml :model, :locals=>{:model=>model}, :layout => false
      when /validation/
        haml :validation, :locals=>{:model=>model}, :layout => false
      else
        return "unable to render model: id #{params[:id]}, view #{params[:view]}"
    end
  rescue
    return "unable to render model: id #{params[:id]}, view #{params[:view]}"
  end
end

get '/predict/?' do 
  @models = ToxCreateModel.all(:order => [ :created_at.desc ])
  @models = @models.collect{|m| m if m.status == 'Completed'}.compact
  haml :predict
end

get '/create' do
  haml :create
end

get '/help' do
  haml :help
end

get "/confidence" do
  haml :confidence
end

# proxy to get data from compound service
# (jQuery load does not work with external URIs)
get %r{/compound/(.*)} do |inchi|
  inchi = URI.unescape request.env['REQUEST_URI'].sub(/^\//,'').sub(/.*compound\//,'')
  OpenTox::Compound.from_inchi(inchi).to_names.join(', ')
end

post '/models' do # create a new model
  unless params[:file] and params[:file][:tempfile] #params[:endpoint] and 
    flash[:notice] = "Please upload a Excel or CSV file."
    redirect url_for('/create')
  end

  unless logged_in()
    logout
    flash[:notice] = "Please login to create a new model."
    redirect url_for('/create')
  end

  @model = ToxCreateModel.create(:name => params[:file][:filename].sub(/\..*$/,""), :subjectid => session[:subjectid])
  @model.update :web_uri => url_for("/model/#{@model.id}", :full)
  @model.save
  task = OpenTox::Task.create("Uploading dataset and creating lazar model",url_for("/models",:full)) do

    @model.update :status => "Uploading and saving dataset"
    begin
      @dataset = OpenTox::Dataset.create(nil, session[:subjectid])
      # check format by extension - not all browsers provide correct content-type]) 
      case File.extname(params[:file][:filename])
      when ".csv"
        csv = params[:file][:tempfile].read
        LOGGER.debug csv
        @dataset.load_csv(csv)
      when ".xls", ".xlsx"
        @dataset.load_spreadsheet(Excel.new params[:file][:tempfile].path)
      else
        error "#{params[:file][:filename]} has a unsupported file type."
      end
    rescue => e
      error "Dataset creation failed with #{e.message}"
    end
    subjectid = session[:subjectid] if session[:subjectid]
    @dataset.save(subjectid)
    if @dataset.compounds.size < 10
      error "Too few compounds to create a prediction model. Did you provide compounds in SMILES format and classification activities as described in the #{link_to "instructions", "/excel_format"}? As a rule of thumb you will need at least 100 training compounds for nongeneric datasets. A lower number could be sufficient for congeneric datasets."
    end
    if @dataset.features.keys.size != 1
      error "More than one feature in dataset #{params[:file][:filename]}. Please delete irrelvant columns and try again."
    end
    if @dataset.metadata[OT.Errors]
      error "Incorrect file format. Please follow the instructions for #{link_to "Excel", "/excel_format"} or #{link_to "CSV", "/csv_format"} formats."
    end
    @model.training_dataset = @dataset.uri
    @model.nr_compounds = @dataset.compounds.size
    @model.warnings = @dataset.metadata[OT.Warnings] unless @dataset.metadata[OT.Warnings].empty?
    @model.save

    @model.update :status => "Creating prediction model"
    begin
      lazar = OpenTox::Model::Lazar.create(:dataset_uri => @dataset.uri, :subjectid => session[:subjectid])
    rescue => e
      error "Model creation failed with '#{e.message}'. Please check if the input file is in a valid #{link_to "Excel", "/excel_format"} or #{link_to "CSV", "/csv_format"} format."
    end
    LOGGER.debug lazar.metadata.to_yaml
    @model.feature_dataset = lazar.metadata[OT.featureDataset]
    @model.uri = lazar.uri
    case lazar.metadata[OT.isA]
    when /Classification/
      @model.type = "classification"
    when /Regression/
      @model.type = "regression"
    else
      @model.type = "unknown"
    end
    @model.save

    unless url_for("",:full).match(/localhost/)
      @model.update :status => "Validating model"
      begin
        validation = OpenTox::Validation.create_crossvalidation(
          :algorithm_uri => OpenTox::Algorithm::Lazar.uri,
          :dataset_uri => lazar.parameter("dataset_uri"),
          :subjectid => session[:subjectid],
          :prediction_feature => lazar.parameter("prediction_feature"),
          :algorithm_params => "feature_generation_uri=#{lazar.parameter("feature_generation_uri")}"
        )
        @model.update(:validation_uri => validation.uri)
        LOGGER.debug "Validation URI: #{@model.validation_uri}"
      rescue => e
        LOGGER.debug "Model validation failed with #{e.message}."
        @model.warnings += "Model validation failed with #{e.message}."
      end

      # create summary
      validation.summary(@model.type).each{|k,v| eval "@model.#{k.to_s} = v"}
      @model.save
      
      @model.update :status => "Creating validation report"
      begin
        @model.update(:validation_report_uri => validation.create_report)
      rescue => e
        LOGGER.debug "Validation report generation failed with #{e.message}."
        @model.warnings += "Validation report generation failed with #{e.message}."
      end

      @model.update :status => "Creating QMRF report"
      begin
        @model.update(:validation_qmrf_report_uri => validation.create_qmrf_report)
      rescue => e
        LOGGER.debug "Validation QMRF report generation failed with #{e.message}."
        @model.warnings += "Validation QMRF report generation failed with #{e.message}."
      end
    end



    #@model.warnings += "<p>Incorrect Smiles structures (ignored):</p>" + parser.smiles_errors.join("<br/>") unless parser.smiles_errors.empty?
    #@model.warnings += "<p>Irregular activities (ignored):</p>" + parser.activity_errors.join("<br/>") unless parser.activity_errors.empty?
    #duplicate_warnings = ''
    #parser.duplicates.each {|inchi,lines| duplicate_warnings += "<p>#{lines.join('<br/>')}</p>" if lines.size > 1 }
    #@model.warnings += "<p>Duplicated structures (all structures/activities used for model building, please  make sure, that the results were obtained from <em>independent</em> experiments):</p>" + duplicate_warnings unless duplicate_warnings.empty?
    @model.update :status => "Completed"
    lazar.uri
  end
  @model.update(:task_uri => task.uri)
  @model.save

  flash[:notice] = "Model creation and validation started - this may last up to several hours depending on the number and size of the training compounds."
  redirect url_for('/models')

=begin
=end
end

post '/predict/?' do # post chemical name to model
  @identifier = params[:identifier]
  unless params[:selection] and params[:identifier] != ''
    flash[:notice] = "Please enter a compound identifier and select an endpoint from the list."
    redirect url_for('/predict')
  end
  begin
    @compound = OpenTox::Compound.from_name(params[:identifier])
  rescue
    flash[:notice] = "Could not find a structure for '#{@identifier}'. Please try again."
    redirect url_for('/predict')
  end
  @predictions = []
  params[:selection].keys.each do |id|
    model = ToxCreateModel.get(id.to_i)
    #model.process unless model.uri
    prediction = nil
    confidence = nil
    title = nil
    db_activities = []
    lazar = OpenTox::Model::Lazar.new model.uri
    prediction_dataset_uri = lazar.run(:compound_uri => @compound.uri, :subjectid => session[:subjectid])
    prediction_dataset = OpenTox::LazarPrediction.find(prediction_dataset_uri)
    if prediction_dataset.metadata[OT.hasSource].match(/dataset/)
      @predictions << {
        :title => model.name,
        :measured_activities => prediction_dataset.measured_activities(@compound)
      }
    else
      predicted_feature = prediction_dataset.metadata[OT.dependentVariables]
      prediction = OpenTox::Feature.find(predicted_feature)
      LOGGER.debug prediction.to_yaml
      if prediction.metadata[OT.error]
        @predictions << {
          :title => model.name,
          :error => prediction.metadata[OT.error]
          }
      else
        @predictions << {
          :title => model.name,
          :model_uri => model.uri,
          :prediction => prediction.metadata[OT.prediction],
          :confidence => prediction.metadata[OT.confidence]
          }
      end
    end
    # TODO failed/unavailable predictions
=begin
    source = prediction.creator
    if prediction.data[@compound.uri]
      if source.to_s.match(/model/) # real prediction
        prediction = prediction.data[@compound.uri].first.values.first
        #LOGGER.debug prediction[File.join(CONFIG[:services]["opentox-model"],"lazar#classification")]
        #LOGGER.debug prediction[File.join(CONFIG[:services]["opentox-model"],"lazar#confidence")]
        if !prediction[File.join(CONFIG[:services]["opentox-model"],"lazar#classification")].nil?
          @predictions << {
            :title => model.name,
            :model_uri => model.uri,
            :prediction => prediction[File.join(CONFIG[:services]["opentox-model"],"lazar#classification")],
            :confidence => prediction[File.join(CONFIG[:services]["opentox-model"],"lazar#confidence")]
            }
        elsif !prediction[File.join(CONFIG[:services]["opentox-model"],"lazar#regression")].nil?
          @predictions << {
            :title => model.name,
            :model_uri => model.uri,
            :prediction => prediction[File.join(CONFIG[:services]["opentox-model"],"lazar#regression")],
            :confidence => prediction[File.join(CONFIG[:services]["opentox-model"],"lazar#confidence")]
            }
        end
      else # database value
        prediction = prediction.data[@compound.uri].first.values
        @predictions << {:title => model.name, :measured_activities => prediction}
      end
    else
      @predictions << {:title => model.name, :prediction => "not available (not enough similar compounds in the training dataset)"}
    end
=end
  end
  LOGGER.debug @predictions.inspect

  haml :prediction
end

post "/lazar/?" do # get detailed prediction
  @page = 0
  @page = params[:page].to_i if params[:page]
  @model_uri = params[:model_uri]
  lazar = OpenTox::Model::Lazar.new @model_uri
  prediction_dataset_uri = lazar.run(:compound_uri => params[:compound_uri], :subjectid => params[:subjectid])
  @prediction = OpenTox::LazarPrediction.find(prediction_dataset_uri)
  @compound = OpenTox::Compound.new(params[:compound_uri])
  #@title = prediction.metadata[DC.title]
  # TODO dataset activity
  #@activity = prediction.metadata[OT.prediction]
  #@confidence = prediction.metadata[OT.confidence]
  #@neighbors = []
  #@features = []
#  if @prediction.data[@compound.uri]
#    if @prediction.creator.to_s.match(/model/) # real prediction
#      p = @prediction.data[@compound.uri].first.values.first
#      if !p[File.join(CONFIG[:services]["opentox-model"],"lazar#classification")].nil?
#        feature = File.join(CONFIG[:services]["opentox-model"],"lazar#classification")
#      elsif !p[File.join(CONFIG[:services]["opentox-model"],"lazar#regression")].nil?
#        feature = File.join(CONFIG[:services]["opentox-model"],"lazar#regression")
#      end
#      @activity = p[feature]
#      @confidence = p[File.join(CONFIG[:services]["opentox-model"],"lazar#confidence")]
#      @neighbors = p[File.join(CONFIG[:services]["opentox-model"],"lazar#neighbors")]
#      @features = p[File.join(CONFIG[:services]["opentox-model"],"lazar#features")]
#    else # database value
#      @measured_activities = @prediction.data[@compound.uri].first.values
#    end
#  else
#    @activity = "not available (no similar compounds in the training dataset)"
#  end
  haml :lazar
end

post '/login' do
=begin
  if session[:subjectid] != nil
    flash[:notice] = "You are already logged in as user: #{session[:username]}. Please log out first."
    redirect url_for('/login')
  end
=end
  if params[:username] == '' || params[:password] == ''
    flash[:notice] = "Please enter username and password."
    redirect url_for('/login')
  end
  if login(params[:username], params[:password])
    flash[:notice] = "Welcome #{session[:username]}!"
    redirect url_for('/create')
    #haml :create
  else
    flash[:notice] = "Login failed. Please try again."
    haml :login
  end
end

post '/logout' do
  logout
  redirect url_for('/login')
end

delete '/model/:id/?' do
  model = ToxCreateModel.get(params[:id])
  begin
    RestClient.delete(model.uri, :subjectid => session[:subjectid]) if model.uri
    RestClient.delete model.task_uri if model.task_uri
    model.destroy
    unless ToxCreateModel.get(params[:id])
      begin
        aa = OpenTox::Authorization.delete_policies_from_uri(model.web_uri, session[:subjectid])
        LOGGER.debug "Policy deleted for Dataset URI: #{uri} with result: #{aa}"
      rescue
        LOGGER.warn "Policy delete error for Dataset URI: #{uri}"
      end
    end
    flash[:notice] = "#{model.name} model deleted."
  rescue
    flash[:notice] = "#{model.name} model delete error."
  end
  redirect url_for('/models')
end

delete '/?' do
  DataMapper.auto_migrate!
  response['Content-Type'] = 'text/plain'
  "All Models deleted."
end

# SASS stylesheet
get '/stylesheets/style.css' do
  headers 'Content-Type' => 'text/css; charset=utf-8'
  sass :style
end
