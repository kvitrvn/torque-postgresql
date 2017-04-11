module Torque
  module PostgreSQL
    class AuxiliaryStatement

      # The settings collector class
      Settings = Collector.new(:attributes, :join, :join_type, :query)

      class << self
        # These attributes require that the class is setup
        #
        # The attributes separation means
        # exposed_attributes -> Will be projected to the main query
        # selected_attributes -> Will be selected on the configurated query
        # join_attributes -> Will be used to join the the queries
        [:exposed_attributes, :selected_attributes, :join_attributes, :table, :query,
          :join_type].each do |attribute|
          define_method(attribute) do
            setup
            instance_variable_get("@#{attribute}")
          end
        end

        # Find or create the class that will handle statement
        def lookup(name, base)
          const = name.to_s.camelize << '_' << self.name.demodulize
          return base.const_get(const) if base.const_defined?(const)
          base.const_set(const, Class.new(AuxiliaryStatement))
        end

        # Set a configuration block, if the class is already set up, just clean
        # the query and wait it to be setup again
        def configurator(block)
          @config = block
          @query = nil if setup?
        end

        # Get the base class associated to this statement
        def base
          self.parent
        end

        # Get the arel table of the base class
        def base_table
          base.arel_table
        end

        # Get the arel table of the query
        def query_table
          query.arel_table
        end

        private
          # Just setup the class if it's not setup
          def setup
            setup! unless setup?
          end

          # Check if the class is setup
          def setup?
            defined?(@query) && @query
          end

          # Setup the class
          def setup!
            # attributes key
            # Provides a map of attributes to be exposed to the main query.
            #
            # For instace, if the statement query has an 'id' column that you
            # want it to be accessed on the main query as 'item_id',
            # you can use:
            #   attributes id: :item_id
            #
            # If its statement has more tables, and you want to expose those
            # fields, then:
            #   attributes 'table.name': :item_name
            #
            # join_type key
            # Changes the type of the join and set the constraints
            #
            # The left side of the hash is the source table column, the right
            # side is the statement table column, now it's only accepting '='
            # constraints
            #   join id: :user_id
            #   join id: :'user.id'
            #   join 'post.id': :'user.last_post_id'
            #
            # It's possible to change the default type of join
            #   join :left, id: :user_id
            #
            # join key
            # Changes the type of the join
            #
            # query key
            # Save the query command to be performand
            settings = Settings.new
            @config.call(settings)

            table_name = self.name.demodulize.split('_').first.underscore
            @join_type = settings.join_type || :inner
            @table = Arel::Table.new(table_name)
            @query = settings.query

            @selected_attributes = []
            @exposed_attributes = []
            @join_attributes = []

            # Iterate the attributes settings
            # Attributes (left => right)
            #   left -> query.selected_attributes AS right
            #   right -> table.exposed_attributes
            settings.attributes.each do |left, right|
              @exposed_attributes << project(right)
              @selected_attributes << project(left, query_table).as(right.to_s)
            end

            # Iterate the join settings
            # Join (left => right)
            #   left -> base.join_attributes.eq(right)
            #   right -> table.selected_attributes
            if settings.join.nil?
              check_auto_join
            else
              settings.join.each do |left, right|
                @selected_attributes << project(right, query_table)
                @join_attributes << project(left, base_table).eq(project(right))
              end
            end
          end

          # Check if it's possible to identify the connection between the main
          # query and the statement query
          def check_auto_join
            foreign_key = base.name.foreign_key
            if query.columns_hash.key?(foreign_key)
              primary_key = project(base.primary_key, base_table)
              @selected_attributes << project(foreign_key, query_table)
              @join_attributes << primary_key.eq(project(foreign_key))
            end
          end

          # Project a column on a given table, or use the column table
          def project(column, table = @table)
            if column.to_s.include?('.')
              table, column = column.split('.')
              table = Arel::Table.new(table)
            end

            table[column]
          end
      end

      # Start a new auxiliary statement giving extra options
      def initialize(*args)
        @options = args.extract_options!
      end

      # Get the columns that will be selected for this statement
      def columns
        self.class.exposed_attributes
      end

      # Build the statement on the given arel and return the WITH statement
      def build_arel(arel)
        klass = self.class
        query = klass.query.select(*klass.selected_attributes)

        # Build the join for this statement
        arel.join(klass.table, arel_join).on(*klass.join_attributes)

        # Return the subquery for this statement
        Arel::Nodes::As.new(klass.table, query.send(:build_arel))
      end

      private

        # Get the class of the join on arel
        def arel_join
          case @options.fetch(:join_type, self.class.join_type)
          when :inner then Arel::Nodes::InnerJoin
          when :left then Arel::Nodes::OuterJoin
          when :right then Arel::Nodes::RightOuterJoin
          when :full then Arel::Nodes::FullOuterJoin
          else
            raise ArgumentError, <<-MSG.gsub(/^ +| +$|\n/, '')
              The '#{@join_type}' is not implemented as a join type.
            MSG
          end
        end

    end
  end
end