# Since the rake task is typically done outside rails env, we setup load
# path to include the lib dir
$:.unshift "#{File.dirname(__FILE__)}/.."
ENV['RAILS_ENV'] ||= 'development'

require 'fileutils'
require 'date'
require 'time'
require 'rubber/configuration'

namespace :rubber do

  def rubber_env()
    Rubber::Configuration.rubber_env
  end

  def rubber_instances()
    Rubber::Configuration.rubber_instances
  end

  def init_s3()
    Rubber::Configuration.init_s3(rubber_env)
  end

  desc "Generate system config files by transforming the files in the config tree"
  task :config do
    require 'rubber/configuration'
    cfg = Rubber::Configuration.get_configuration(ENV['RAILS_ENV'])
    instance_alias = cfg.environment.current_host
    instance = cfg.instance[instance_alias]
    if instance
      roles = instance.role_names
      env = cfg.environment.bind(roles, instance_alias)
      gen = Rubber::Configuration::Generator.new("#{RAILS_ROOT}/config/rubber", roles, instance_alias)
    elsif RAILS_ENV == 'development'
      roles = cfg.environment.known_roles
      role_items = roles.collect do |r|
        Rubber::Configuration::RoleItem.new(r, r == "db" ? {'primary' => true} : {})
      end
      env = cfg.environment.bind(roles, instance_alias)
      domain = env.domain
      instance = Rubber::Configuration::InstanceItem.new(instance_alias, domain, role_items, 'dummyid')
      instance.external_host = instance.full_name
      instance.external_ip = "127.0.0.1"
      instance.internal_host = instance.full_name
      instance.internal_ip = "127.0.0.1"
      cfg.instance.add(instance)
      gen = Rubber::Configuration::Generator.new("#{RAILS_ROOT}/config/rubber", roles, instance_alias)
      gen.fake_root ="#{RAILS_ROOT}/tmp/rubber"
    else
      puts "Instance not found for host: #{instance_alias}"
      exit 1
    end

    if ENV['NO_POST']
      gen.no_post = true
    end
    if ENV['FILE']
      gen.file_pattern = ENV['FILE']
    end
    if ENV['FORCE']
      gen.force = true
    end
    gen.stop_on_error_cmd = env.stop_on_error_cmd
    gen.run

  end

  desc <<-DESC
    Rotate rails app server logfiles.  Should be run right after midnight.
    The following arguments affect behavior:
    LOG_DIR (required): Directory where log files are located
    LOG_FILE (*.log):   File pattern to match to find logs to rotate
    LOG_AGE (7):        Delete rotated logs older than this many days in the past
  DESC
  task :rotate_logs do
    log_src_dir = get_env('LOG_DIR', true)
    log_file_glob = get_env('LOG_FILES') || "*.log"
    log_file_age = (get_env('LOG_AGE') || 7).to_i

    rotated_date = (Date.today - 1).strftime('%Y%m%d')
    puts "Rotating logfiles located at: #{log_src_dir}/#{log_file_glob}"
    Dir["#{log_src_dir}/#{log_file_glob}"].each do |logfile|
      rotated_file = "#{logfile}.#{rotated_date}"
      if File.exist?(rotated_file)
        rotated_file += "_#{Time.now.to_i}"
      end
      FileUtils.cp(logfile, rotated_file)
      File.truncate logfile, 0
    end

    tdate = Date.today - log_file_age
    threshold = Time.local(tdate.year, tdate.month, tdate.day)
    puts "Cleaning rotated log files older than #{log_file_age} days"
    Dir["#{log_src_dir}/#{log_file_glob}.[0-9]*"].each do |logfile|
      if File.mtime(logfile) < threshold
        FileUtils.rm_f(logfile)
      end
    end
  end

  desc <<-DESC
    Backup database to given backup directory
    The following arguments affect behavior:
    BACKUP_DIR (required): Directory where db backups will be stored
    BACKUP_AGE (7):        Delete rotated logs older than this many days in the past
    DBUSER (required)      User to connect to the db as
    DBPASS (optional):     Pass to connect to the db with
    DBHOST (required):     Host where the db is
    DBNAME (required):     Database name to backup
  DESC
  task :backup_db do
    system "touch /tmp/fullbackup-running"
    
    dir = get_env('BACKUP_DIR', true)
    age = (get_env('BACKUP_AGE') || 3).to_i
    time_stamp = Time.now.strftime("%Y-%m-%d_%H-%M")
    backup_file = "#{dir}/#{RAILS_ENV}_dump_#{time_stamp}.sql.gz"
    FileUtils.mkdir_p(File.dirname(backup_file))

    user = get_env('DBUSER', true)
    pass = get_env('DBPASS')
    pass = nil if pass.strip.size == 0
    host = get_env('DBHOST', true)
    name = get_env('DBNAME', true)
    
    raise "No db_backup_cmd defined in rubber.yml, cannot backup!" unless rubber_env.db_backup_cmd
    db_backup_cmd = rubber_env.db_backup_cmd.gsub(/%([^%]+)%/, '#{\1}')
    db_backup_cmd = eval('%Q{' + db_backup_cmd + '}')
    
    puts "Backing up database with command:"
    sh db_backup_cmd
    puts "Created backup: #{backup_file}"
    
    s3_prefix = "db/"
    if rubber_env.ec2_backup_bucket
      init_s3
      unless AWS::S3::Bucket.list.find { |b| b.name == rubber_env.ec2_backup_bucket }
        AWS::S3::Bucket.create(rubber_env.ec2_backup_bucket)
      end
      dest = "#{s3_prefix}#{File.basename(backup_file)}"
      puts "Saving db backup to S3: #{rubber_env.ec2_backup_bucket}:#{dest}"
      AWS::S3::S3Object.store(dest, open(backup_file), rubber_env.ec2_backup_bucket)
    end

    tdate = Date.today - age
    threshold = Time.local(tdate.year, tdate.month, tdate.day)
    puts "Cleaning backups older than #{age} days"
    Dir["#{dir}/*"].each do |file|
      if File.mtime(file) < threshold
        puts "Deleting #{file}"
        FileUtils.rm_f(file)
      end
    end
    
    if rubber_env.ec2_backup_bucket
      puts "Cleaning S3 backups older than #{age} days from: #{rubber_env.ec2_backup_bucket}:#{s3_prefix}"
      AWS::S3::Bucket.objects(rubber_env.ec2_backup_bucket, :prefix => s3_prefix).clone.each do |obj|
        if Time.parse(obj.about["last-modified"]) < threshold
          puts "Deleting #{obj.key}"
          obj.delete
        end
      end
    end
    
    if rubber_env.ec2_backup_bucket
      puts "Removing all incremental backups"
      AWS::S3::Bucket.objects(rubber_env.ec2_backup_bucket, :prefix => 'db-binlogs/').clone.each do |obj|
        puts "Deleting #{obj.key}"
        obj.delete        
      end
    end
    
    File.delete("/tmp/fullbackup-running")
  end

  desc "Backup binary logs to S3"
  task :backup_binlogs do
    sleep 1
    
    if File.exists?("/tmp/fullbackup-running")
      puts "Full backup is running"
      exit
    end
    
    system %(mysql -e "FLUSH LOGS")

    logs = Dir.glob("/var/log/mysql/mysql-bin.[0-9]*").sort
    logs_to_archive = logs[0..-2]
    init_s3
    logs_to_archive.each do |log|
      puts "Saving #{log}"
      AWS::S3::S3Object.store("db-binlogs/#{File.basename(log)}", open(log), rubber_env.ec2_backup_bucket)
    end

    puts "Purging logs to #{File.basename(logs[-1])}"
    system %(mysql -e "PURGE MASTER LOGS TO '#{File.basename(logs[-1])}'")
  end

  desc <<-DESC
    Restores a database backup from s3.
    This tries to find the last backup made or the s3 object identified by the
    key FILENAME
    The following arguments affect behavior:
    FILENAME (optional):   key of S3 object to use
    DBUSER (required)      User to connect to the db as
    DBPASS (optional):     Pass to connect to the db with
    DBHOST (required):     Host where the db is
    DBNAME (required):     Database name to backup
  DESC
  task :restore_db_s3 do
    file = get_env('FILENAME')
    user = get_env('DBUSER', true)
    pass = get_env('DBPASS')
    pass = nil if pass && pass.strip.size == 0
    host = get_env('DBHOST', true)
    name = get_env('DBNAME', true)
    
    raise "No db_restore_cmd defined in rubber.yml" unless rubber_env.db_restore_cmd
    db_restore_cmd = rubber_env.db_restore_cmd.gsub(/%([^%]+)%/, '#{\1}')
    db_restore_cmd = eval('%Q{' + db_restore_cmd + '}')

    # try to fetch a matching file from s3 (if ec2_backup_bucket given)
    raise "No ec2_backup_bucket defined in rubber.yml" unless rubber_env.ec2_backup_bucket
    if (init_s3 &&
        AWS::S3::Bucket.list.find { |b| b.name == rubber_env.ec2_backup_bucket })
      s3objects = AWS::S3::Bucket.find(rubber_env.ec2_backup_bucket,
                 :prefix => 'db/') 
      if file
        puts "trying to fetch #{file} from s3"
        data = s3objects.detect { |o| file == o.key }
      else
        puts "trying to fetch last modified s3 backup"
        data = s3objects.max {|a,b| a.about["last-modified"] <=> b.about["last-modified"] }
      end
    end
    raise "could not access backup file via s3" unless data

    puts "piping restore data to command [#{db_restore_cmd}]"
    IO.popen (db_restore_cmd, mode='w') do |p|
      data.value do |segment|
        p.write segment
      end
    end

  end


  def get_env(name, required=false)
    value = ENV[name]
    raise("#{name} is required, pass using environment") if required && ! value
    return value
  end

end
