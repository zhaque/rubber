namespace :rubber do
  namespace :thin do
    def invoke_thin(command)
      config = rubber_cfg.environment.bind
      run "cd #{current_path} && thin #{command}" +
        " --servers #{config.appserver_count}" +
        " --port #{config.appserver_base_port}" +
        " --environment #{rails_env}" +
        " --user rails" +
        " --group rails" 
    end
    
    desc "Starts thin"
    task :start, :roles => :app do
      invoke_thin(:start)
    end

    desc "Restarts thin"
    task :restart, :roles => :app do
      invoke_thin(:restart)
    end
    
    desc "Stops thin"
    task :stop, :roles => :app do
      invoke_thin(:stop)
    end

    on :load do
      rubber.serial_task self, :serial_restart, :roles => :app do
        stop
        start
      end
    end

    deploy.task :restart, :roles => :app do
      rubber.thin.restart
    end
    
    deploy.task :stop, :roles => :app do
      rubber.thin.stop
    end

    deploy.task :start, :roles => :app do
      rubber.thin.start
    end
  end
end
