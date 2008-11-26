global = self

desc "Does cold deploy, but instead of running migrations loads data from /db/dump/project.sql"
namespace :koonen do
  namespace :deploy do
    task :cold do
      global.deploy.update
      db.load_dump
      global.deploy.start
    end    
  end
  
  namespace :db do
    desc "Loads /db/dump/project.sql into the database"
    task :load_dump, :roles => :db, :only => { :primary => true } do
      env = rubber_cfg.environment.bind("mysql_master")
      file = "#{current_release}/db/dump/project.sql"
      if capture("test -e #{file} || echo -n no") != 'no'
        logger.info "Loading data from #{file} to #{env.db_name} ..."
        optional_pass = "-p#{env.db_pass}" unless env.db_pass.nil?
        sudo "mysql -u#{env.db_user} #{optional_pass} #{env.db_pass} #{env.db_name} < #{file}"
      else
        logger.info "There are no database dump at #{file}"
      end
    end    
  end  
end
