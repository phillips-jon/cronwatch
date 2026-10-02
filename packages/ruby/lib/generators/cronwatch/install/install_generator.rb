# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"
require "cronwatch/active_record"

module Cronwatch
  module Generators
    # bin/rails generate cronwatch:install
    #
    # Writes a migration for the three tables the ActiveRecord store uses
    # (created with the SDK's own DDL, so a Node process can share them) and
    # config/initializers/cronwatch.rb, then prints how to schedule
    # Cronwatch::CheckJob and mount the dashboard. With --database, the
    # migration goes to that database and app/models/cronwatch_record.rb, an
    # abstract class connected to it, is the store's connection_class, so the
    # store reads the tables where the migration made them. The templates
    # live in this file so the gem ships nothing but Ruby.
    class InstallGenerator < ::Rails::Generators::Base
      include ::ActiveRecord::Generators::Migration

      desc "Creates the CronWatch migration and initializer."

      class_option :prefix, type: :string, default: Cronwatch::Stores::ActiveRecord::DEFAULT_PREFIX,
                            desc: "Table name prefix: lowercase letters, digits and underscores"
      class_option :database, type: :string, aliases: %i[--db],
                              desc: "The database for the tables, in an app with several (from config/database.yml)"

      # The abstract class --database writes, which the store connects through.
      RECORD_CLASS = "CronwatchRecord"

      def check_prefix
        Cronwatch::Stores::ActiveRecord.table_prefix(options[:prefix])
      rescue ArgumentError => e
        raise ::Thor::Error, e.message
      end

      def create_migration_file
        dir = db_migrate_path
        absolute = File.join(destination_root, dir)
        if (existing = self.class.migration_exists?(absolute, migration_name))
          say_status :exist, existing.delete_prefix("#{destination_root}/"), :blue
          return
        end

        number = self.class.next_migration_number(absolute)
        create_file File.join(dir, "#{number}_#{migration_name}.rb"), migration
      end

      def create_connection_class
        return unless database_name

        create_file "app/models/cronwatch_record.rb", connection_class
      end

      def create_initializer
        create_file "config/initializers/cronwatch.rb", initializer
      end

      def show_next_steps
        say next_steps
      end

      private

      # create_cronwatch_tables, or with a prefix create_cronwatch_ops_tables,
      # so each prefix gets a migration of its own.
      def migration_name
        prefix = options[:prefix]
        return "create_cronwatch_tables" if prefix == Cronwatch::Stores::ActiveRecord::DEFAULT_PREFIX

        "create_cronwatch_#{prefix.squeeze("_").delete_prefix("_").delete_suffix("_")}_tables"
      end

      # The --database name, or nil.
      def database_name
        name = options[:database].to_s
        name.empty? ? nil : name
      end

      def store_args
        prefix = options[:prefix]
        args = []
        args << "prefix: #{prefix.inspect}" unless prefix == Cronwatch::Stores::ActiveRecord::DEFAULT_PREFIX
        # Named, not referenced, so the initializer does not load an app class at boot.
        args << "connection_class: #{RECORD_CLASS.inspect}" if database_name
        args.empty? ? "" : "(#{args.join(", ")})"
      end

      def connection_class
        <<~RUBY
          # frozen_string_literal: true

          # The #{database_name} database, where CronWatch keeps its tables. The store in
          # config/initializers/cronwatch.rb connects through this class.
          class #{RECORD_CLASS} < ActiveRecord::Base
            self.abstract_class = true

            connects_to database: { writing: :#{database_name} }
          end
        RUBY
      end

      def migration
        <<~RUBY
          # frozen_string_literal: true

          require "cronwatch/active_record"

          # The tables CronWatch keeps jobs, runs and alert state in. They are
          # created with the SDK's own statements, so a Node process using
          # @cronwatch/sdk can share them.
          class #{migration_name.camelize} < ActiveRecord::Migration[#{::ActiveRecord::Migration.current_version}]
            def up
              Cronwatch::Stores::ActiveRecord.create_tables!(connection, prefix: #{options[:prefix].inspect})
            end

            def down
              Cronwatch::Stores::ActiveRecord.drop_tables!(connection, prefix: #{options[:prefix].inspect})
            end
          end
        RUBY
      end

      def initializer
        <<~RUBY
          # frozen_string_literal: true

          # CronWatch: told when a scheduled job is missed, failed, stuck, slow,
          # over budget or under its floor. https://cronwatch.dev/docs/
          #
          # Monitor a job by including Cronwatch::ActiveJob and declaring its schedule:
          #
          #   class NightlyReportJob < ApplicationJob
          #     include Cronwatch::ActiveJob
          #     cronwatch schedule: "0 2 * * *", grace: "15m"
          #   end
          #
          # and run Cronwatch::CheckJob every few minutes to catch the runs that never happen.
          Cronwatch.configure do |c|
            # Jobs, runs and alert state, in #{database_name ? "the #{database_name} database (see app/models/cronwatch_record.rb)" : "this app's database"}.
            c.store = Cronwatch::Stores::ActiveRecord.new#{store_args}

            # Where alerts go. With none set, they are written to standard error.
            c.alerts = [
              (Cronwatch::Alerts::Slack.new(webhook_url: ENV["SLACK_WEBHOOK_URL"]) if ENV["SLACK_WEBHOOK_URL"].present?),
              # Cronwatch::Alerts::Discord.new(webhook_url: ENV["DISCORD_WEBHOOK_URL"]),
              # Cronwatch::Alerts::Webhook.new(url: ENV["CRONWATCH_WEBHOOK_URL"], secret: ENV["CRONWATCH_WEBHOOK_SECRET"]),
            ].compact.presence

            # How long finished runs are kept. Each job's newest run is always kept.
            # c.retention = "30d"

            # Applied to every job that does not set its own.
            # c.defaults = { grace: "10m", timezone: "Europe/London", failures_before_alert: 1 }

            # Called with (error, where) when the store, a channel or triage fails. Default: Rails.logger.
            # c.on_error = ->(error, where) { Rails.error.report(error, handled: true, context: { cronwatch: where }) }

            # The bearer secret the dashboard's check endpoint takes. Default: ENV["CRON_SECRET"].
            # c.cron_secret = Rails.application.credentials.cron_secret
          end
        RUBY
      end

      # What the next steps say about --database after the migrate line, or "".
      def database_step
        return "" unless database_name

        "\n\n   The store connects through #{RECORD_CLASS} (app/models/cronwatch_record.rb),\n   " \
          "which connects_to the #{database_name} database named in config/database.yml."
      end

      def next_steps
        <<~TEXT

          CronWatch is installed. Next:

          1. Create the tables#{database_name ? " in the #{database_name} database" : ""}:

               bin/rails db:migrate#{database_step}

          2. Monitor a job:

               class NightlyReportJob < ApplicationJob
                 include Cronwatch::ActiveJob
                 cronwatch schedule: "0 2 * * *", grace: "15m" # name: "nightly-report"
               end

          3. Run Cronwatch::CheckJob every 5 minutes, from one scheduler only. It notices
             the runs that never happen; two checkers would send each alert twice.

             Solid Queue, in config/recurring.yml:

               production:
                 cronwatch_check:
                   class: Cronwatch::CheckJob
                   schedule: every 5 minutes

             sidekiq-cron, in config/schedule.yml:

               cronwatch_check:
                 cron: "*/5 * * * *"
                 class: "Cronwatch::CheckJob"

             Or from a crontab: bin/rails cronwatch:check

          4. Mount the dashboard in config/routes.rb:

               mount Cronwatch.client.routes => "/cronwatch"

             Outside development it needs CRONWATCH_TOKEN set to sign in. In
             development, without one, the server prints a sign-in link on
             the dashboard's first request.

        TEXT
      end
    end
  end
end
