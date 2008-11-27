namespace :rubber do
  namespace :solr do
    rubber.allow_optional_tasks(self)
  
    desc "Stops Solr"
    task :stop, :roles => :solr do
      run "RAILS_ENV=#{RAILS_ENV} #{current_path}/mySolr/solr.stop"
    end
    
    desc "Starts Solr"
    task :start, :roles => :solr do
      run "RAILS_ENV=#{RAILS_ENV} #{current_path}/mySolr/solr.start"
    end
    
    desc "Restarts Solr"
    task :restart, :roles => :solr do
      run "RAILS_ENV=#{RAILS_ENV} #{current_path}/mySolr/solr.restart"
    end
  end
end
