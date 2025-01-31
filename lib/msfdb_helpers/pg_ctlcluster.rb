require 'msfdb_helpers/db_interface'

module MsfdbHelpers
  class PgCtlcluster < DbInterface

    def initialize(db_path:, options:, localconf:, db_conf:)
      @db = db_path
      @options = options
      @pg_version = get_postgres_version
      @localconf = localconf
      @db_conf = db_conf
      @pg_cluster_conf_root = "#{@localconf}/.local/etc/postgresql"
      ENV['PG_CLUSTER_CONF_ROOT'] = @pg_cluster_conf_root
      super(options)
    end

    def init(msf_pass, msftest_pass)
      if Dir.exist?(@db)
        puts "Found a database at #{@db}, checking to see if it is started"
        start
        return
      end

      if File.exist?(@db_conf) && !@options[:delete_existing_data]
        if !load_db_config
          puts 'Failed to load existing database config. Please reinit and overwrite the file.'
          return
        end
      else
        write_db_config
      end

      puts "Creating database at #{@db}"
      Dir.mkdir(@db)
      FileUtils.mkdir_p(@pg_cluster_conf_root)
      run_cmd("pg_createcluster --user=$(whoami) -l #{@db}/log -d #{@db} -s /tmp --encoding=UTF8 #{@pg_version} #{@options[:msf_db_name]} -- --username=$(whoami) --auth-host=trust --auth-local=trust")
      File.open("#{@pg_cluster_conf_root}/#{@pg_version}/#{@options[:msf_db_name]}/postgresql.conf", 'a') do |f|
        f.puts "port = #{@options[:db_port]}"
      end

      start

      create_db_users(msf_pass, msftest_pass)

      write_db_client_auth_config
      restart
    end

    def delete
      if Dir.exist?(@db)
        stop

        if @options[:delete_existing_data]
          puts "Deleting all data at #{@db}"
          run_cmd("pg_dropcluster #{@pg_version} #{@options[:msf_db_name]}")
          FileUtils.rm_rf(@db)
          FileUtils.rm_rf("#{@localconf}/.local/etc/postgresql")
          File.delete(@db_conf)
        end
      else
        puts "No data at #{@db}, doing nothing"
      end
    end

    def reinit(msf_pass, msftest_pass)
      delete
      init(msf_pass, msftest_pass)
    end

    def start
      print "Starting database at #{@db}..."
      status = run_cmd("pg_ctlcluster #{@pg_version} #{@options[:msf_db_name]} start -- -o \"-p #{@options[:db_port]}\" -D #{@db} -l #{@db}/log")
      case status
      when 0
        puts 'success'.green.bold.to_s
        return true
      when 2
        puts "Database already started at #{@db}"
        return true
      else
        puts 'failed'.red.bold.to_s
        return false
      end
    end

    def stop
      run_cmd("pg_ctlcluster #{get_postgres_version} #{@options[:msf_db_name]} stop -- -o \"-p #{@options[:db_port]}\" -D #{@db}")
    end

    def restart
      run_cmd("pg_ctlcluster #{@pg_version} #{@options[:msf_db_name]} reload -- -o \"-p #{@options[:db_port]}\" -D #{@db} -l #{@db}/log")
    end

    def status
      if Dir.exist?(@db)
        if run_cmd("pg_ctlcluster #{@pg_version} #{@options[:msf_db_name]} status -- -o \"-p #{@options[:db_port]}\" -D #{@db}") == 0
          puts "Database started at #{@db}"
        else
          puts "Database is not running at #{@db}"
        end
      else
        puts "No database found at #{@db}"
      end
    end

    def write_db_client_auth_config
      client_auth_config = "#{@pg_cluster_conf_root}/#{@pg_version}/#{@options[:msf_db_name]}/pg_hba.conf"
      super(client_auth_config)
    end

    def self.requirements
      %w[psql pg_ctlcluster pg_dropcluster pg_createcluster pg_config]
    end

    private

    def get_postgres_version
      output, _status = Open3.capture2('pg_config --version')    # Example outputs
      # PostgreSQL 12.6 (Ubuntu 12.6-0ubuntu0.20.04.1)
      # PostgreSQL 13.2 (Debian 13.2-1)
      # PostgreSQL 11.11
      /PostgreSQL\s(?<version>\d+)\.\d+/ =~ output
      version
    end

    def create_db_users(msf_pass, msftest_pass)
      puts 'Creating database users'
      run_psql("create user #{@options[:msf_db_user]} with password '#{msf_pass}'")
      run_psql("create user #{@options[:msftest_db_user]} with password '#{msftest_pass}'")
      run_psql("alter role #{@options[:msf_db_user]} createdb")
      run_psql("alter role #{@options[:msftest_db_user]} createdb")
      run_psql("alter role #{@options[:msf_db_user]} with password '#{msf_pass}'")
      run_psql("alter role #{@options[:msftest_db_user]} with password '#{msftest_pass}'")

      conn = PG.connect(host: @options[:db_host], dbname: 'postgres', port: @options[:db_port], user: @options[:msf_db_user], password: msf_pass)
      conn.exec("CREATE DATABASE #{@options[:msf_db_name]}")
      conn.exec("CREATE DATABASE #{@options[:msftest_db_name]}")
      conn.finish
    end

  end
end
