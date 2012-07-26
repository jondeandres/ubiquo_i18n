module UbiquoI18n
  module Extensions
    module ActiveRecord

      def self.append_features(base)
        super
        base.extend(ClassMethods)
        base.send :include, InstanceMethods
        base.send :alias_method_chain, :clone, :i18n_fields_ignore
        base.send :alias_method_chain, :attributes=, :i18n_fields_assignement_advancement
      end

      module ClassMethods

        # Class method for ActiveRecord that states which attributes are translatable and therefore when updated will be only updated for the current locale.
        #
        # EXAMPLE:
        #
        #   translatable :title, :description
        #
        # possible options:
        #   :timestamps => set to false to avoid translatable (i.e. independent per translation) timestamps

        def translatable(*attrs)

          # inherit translatable attributes
          @translatable_attributes = self.translatable_attributes || []

          @really_translatable_class = self
          @translatable = true

          # add the uniqueness validation, clearing it before if it existed
          clear_locale_uniqueness_per_entity_validation
          add_locale_uniqueness_per_entity_validation

          # extract and parse options
          options = attrs.extract_options!
          # add attrs from this class
          @translatable_attributes += attrs

          # timestamps are independent per translation unless set
          @translatable_attributes += [:created_at, :updated_at] unless options[:timestamps] == false
          # when using optimistic locking, lock_version has to be independent per translation
          @translatable_attributes += [:lock_version]

          # try to generate the attribute setter
          self.new.send(:locale=, :generate) rescue nil
          if instance_methods.include?('locale=') && !instance_methods.include?('locale_with_duality=')
            # give the proper behaviour to the locale setter
            define_method('locale_with_duality=') do |locale|
              locale = case locale
              when String
                locale
              else
                locale.iso_code if locale.respond_to?(:iso_code)
              end
              send(:locale_without_duality=, locale)
            end

            alias_method_chain :locale=, :duality

          end

          unless instance_methods.include?("in_locale")
            define_method('in_locale') do |*locales|
              self.class.locale(*locales).first(:conditions => {:content_id => self.content_id})
            end
          end

          # Checks if the instance has a locale in the given a locales list
          # The last parameter can be an options hash
          #   :skip_any => if true, ignore items with the :any locale.
          #                else, these items always return true
          define_method('in_locale?') do |*asked_locales|
            options = asked_locales.extract_options!
            options.reverse_merge!({
              :skip_any => false
            })
            asked_locales.map(&:to_s).include?(self.locale) ||
              (!options[:skip_any] && self.locale == 'any')
          end

          # usage:
          # find all content in any locale: Model.locale(:all)
          # find spanish content: Model.locale('es')
          # find spanish or english content. If spanish and english exists, gets the spanish version. Model.locale('es', 'en')
          # find all content in spanish or any other locale if spanish dosn't exist: Model.locale('es', :all)
          # find all content in any locale: Model.locale(:all)
          #
          named_scope :locale, lambda{|*locales|
            if locales.delete(:ALL)
              locales << :all
              ActiveSupport::Deprecation.warn('Use :all instead of :ALL in locale()', caller(5))
            end

            {:locale_list => locales}
          }

          # Using localized is like using locale(current_locale, :all),
          # but automatically using the possibly defined locale fallback list
          # if the Locale.use_fallbacks flag is enabled
          named_scope :localized, lambda{
            locales = Locale.use_fallbacks ? Locale.fallbacks(Locale.current) : [Locale.current]
            {:locale_list => locales}
          }

          # usage:
          # find all items of one content: Model.content(1).first
          # find all items of some contents: Model.content(1,2,3)
          named_scope :content, lambda{|*content_ids|
            {:conditions => {:content_id => content_ids}}
          }

          # usage:
          # find all translations of a given content: Model.translations(content)
          # will use the defined scopes to discriminate what are translations
          # remember it won't return 'content' itself
          named_scope :translations, lambda{|content|
            scoped_conditions = []
            @translatable_scopes.each do |scope|
                scoped_conditions << (String === scope ? scope : scope.call(content))
            end
            inequality_operator = content.locale ? '!=' : 'IS NOT'
            translation_condition = "#{self.table_name}.content_id = ? AND #{self.table_name}.locale #{inequality_operator} ?"
            unless scoped_conditions.blank?
              translation_condition += ' AND ' + scoped_conditions.join(' AND ')
            end
            {:conditions => [translation_condition, content.content_id, content.locale]}
          }

          # Apply these named scopes to any possible already loaded subclass
          subclasses.each do |klass|
            klass.scopes.merge! scopes.slice(:locale, :translations, :content)
          end

          # Instance method to find translations
          define_method('translations') do
            self.class.send :with_exclusive_scope do
              self.class.translations(self)
            end
          end

          # Returns an array containing self and its translations
          define_method('with_translations') do
            with_translations = [self] + translations.to_a.sort_by(&:id)
            with_translations = with_translations.sort_by(&:id) unless self.new_record?
            with_translations
            [self] + translations
          end

          # Creates a new instance of the translatable class, using the common
          # values from an instance sharing the same content_id
          # Returns a new independent instance if content_id is nil or not found
          # Options can be one of these:
          #   :copy_all => if true, will copy all the attributes from the original, even the translatable ones
          def translate(content_id, locale, options = {})
            original = find_by_content_id(content_id)
            new_translation = original ? original.translate(locale, options) : new
            new_translation.locale = locale
            new_translation
          end

          # Creates (saving) a new translation of self, with the common values filled in
          define_method('translate') do |*attrs|
            locale = attrs.first
            options = attrs.extract_options!
            options[:copy_all] = options[:copy_all].nil? ? true : options[:copy_all]

            new_translation = self.class.new
            new_translation.locale = locale

            # copy of attributes
            clonable_attributes = options[:copy_all] ? :attributes_except_unique_for_translation : :untranslatable_attributes
            self.send(clonable_attributes).each_pair do |attr, value|
              new_translation.send("#{attr}=", value)
            end

            new_translation
          end


          # Looks for defined shared relations and performs a chain-update on them
          define_method('copy_translatable_shared_relations_from') do |model|
            # here a clean environment is needed, but save Locale.current
            without_current_locale((self.locale rescue nil)) do
              self.class.translating_relations do
                must_save = false
                self.class.translation_shared_reflections.each do |association_id, reflection|
                  # if this is a has_many :through, we don't do anything;
                  # this implies that the intermediate table is translation-shared,
                  # which we currently enforce in the definition, or else
                  # the propagation of changes would not work
                  next if reflection.has_many_through_translatable?

                  # Get the associated instances as Rails would return it
                  association_values = model.send("#{association_id}")
                  # Use the first record to determine what to do in this association
                  record = [association_values].flatten.first

                  if record && record.class.is_translatable?

                    # for each associated record, find its appropiate translation
                    # (if existing) and create the contents that it should have
                    all_relationship_contents = [association_values].flatten.reject(&:marked_for_destruction?).map do |related_element|
                      existing_translation = related_element.translations.locale(locale).first
                      existing_translation || related_element
                    end

                  elsif record

                    all_relationship_contents = [association_values].flatten.reject(&:marked_for_destruction?)

                  elsif reflection.macro == :belongs_to
                     # no record means that we are removing an association, so the new content is nil
                    all_relationship_contents = [nil]
                  else
                    # no values on a has_many or has_one
                    all_relationship_contents = []
                  end

                  all_relationship_contents = all_relationship_contents.first unless association_values.is_a?(Array)

                  # Save the new association contents
                  self.send("#{association_id}=", all_relationship_contents)
                  if reflection.macro == :belongs_to && !new_record?
                    # belongs_to is not autosaved by rails when the association is not new
                    must_save = true
                  end
                end
                save if must_save
              end
            end
          end

          # Do any necessary treatment when we are about to propagate changes from an instance to its translations
          define_method 'prepare_for_shared_translations' do
            # Rails doesn't reload the belongs_to associations when the _id field is changed,
            # which causes cached data to persist when it's already obsolete
            self.class.translation_shared_reflections.select do |name, reflection|
              if reflection.macro == :belongs_to
                refresh_reflection_value_if_needed(reflection)
              end
            end
          end

          define_method "refresh_reflection_value_if_needed" do |reflection|
            if has_updated_existing_primary_key(reflection)
              association = self.send("#{reflection.name}_without_shared_translations")
              association.reload if association
            end
          end

          define_method 'destroy_content' do
            self.translations.each(&:destroy)
            self.reload.destroy
          end

        end

        def untranslatable
          @translatable_attributes = []
          @really_translatable_class = nil
          @translatable = nil
          clear_locale_uniqueness_per_entity_validation
        end

        def initialize_translations_for(*associations)
          share_translations_for(associations, {:only_new => true})
          associations.each do |association|
            ["assign_nested_attributes_for_collection_association"].each do |method|
              unless self.method_defined?("#{method}_with_initialization")
                define_method("#{method}_with_initialization") do |*params|
                  # It's being fully assigned, so should no longer return results as an initialized_shared
                  current_association = params.first
                  association_initialized!(current_association)
                  # If these shared results were already loaded, discard them
                  if self.is_association_initialized?(current_association)
                    self.send(current_association).reset
                  end
                  # Now perform the assignation as usual
                  send("#{method}_without_initialization", *params)
                end
                alias_method_chain("#{method}", :initialization)
              end
            end
          end
        end

        def share_translations_for(*associations)
          options = associations.extract_options!
          associations.flatten.each do |association_id|

            reflection = reflections[association_id] or
              raise ::ActiveRecord::ConfigurationError, "Association named '#{association_id}' was not found"

            reflection.mark_as_translation_shared(true, options)

            unless is_translation_shared_initialized? association_id
              define_method "#{association_id}_with_shared_translations" do

                association = self.send("#{association_id}_without_shared_translations")

                return association if !applicable_translation_shared(reflection)

                return association if cached_translation_shared_association(association)

                # preferred locale for the associated objects
                locale = Locale.current || self.locale

                is_collection = association.respond_to? :count

                # the target needs to be loaded, and this works for nils
                association.inspect

                if is_collection

                  # In a has_many :through to an untranslatable model,
                  # we operate from the intermediate table
                  association_to_retrieve = unless reflection.has_many_through_translatable?
                    "#{association_id}_without_shared_translations"
                  else
                    reflection.through_reflection.name
                  end

                  # if this instance is not from a translatable class, it won't have the with_translations method
                  origin = self.class.is_translatable? ? self.with_translations : self

                  # retrieve an element for each content_id
                  contents = []
                  Array(origin).each do |translation|
                    elements = translation.send(association_to_retrieve)
                    elements.each do |element|
                      contents << element unless element.class.is_translatable? && element.content_id && contents.map(&:content_id).include?(element.content_id)
                    end
                  end

                  # build the complete proxy_target and replace its contents
                  target = association.proxy_target
                  target.clear

                  extra_locales_in_order = self.class.is_translatable? ? (Array(origin).map(&:locale) - [locale]) : []

                  if reflection.has_many_through_translatable?
                    target.concat(contents.map(&reflection.source_reflection.name))
                  else
                    target.concat(contents)

                    # now "localize" the contents
                    translations_to_do = {}
                    target.each do |element|
                      if element.class.is_translatable? && !element.in_locale?(locale) && (translation = element.in_locale(locale, *extra_locales_in_order))
                        translations_to_do[element] = translation
                      end
                    end
                    translations_to_do.each_pair do |foreign, translation|
                      target.delete foreign
                      target << translation
                    end
                  end

                  association.loaded
                  association.instance_variable_set(:@loaded_in_locale, Locale.current)

                # it's a proxy and sometimes does not return the same as .nil?
                elsif !is_collection && !association.is_a?(NilClass)
                  # one-sized association, not a collection
                  if association.class.is_translatable? && !association.in_locale?(locale)
                    association = association.in_locale(locale) || association
                  end

                elsif association.is_a?(NilClass) && self.class.reflect_on_association(association_id).macro == :has_one
                  # in a has_one, with a nil association we have to look at translations
                  translations.map do |translation|
                    element = translation.send("#{association_id}_without_shared_translations")
                    if element
                      if element.class.is_translatable? && !element.in_locale?(locale)
                        element = element.in_locale(locale) || element
                      end
                      association = element
                      break
                    end
                  end

                end

                association
              end

              alias_method_chain association_id, :shared_translations

              # Syncs the deletion of association elements across translations
              add_association_callbacks(
                association_id,
                :after_remove => Proc.new { |record, removed|
                  record.class.translating_relations do
                    if reflections[association_id].is_translation_shared?

                      # Tell to the record translations that this element has been removed
                      record.translations.each do |translation|
                        to_remove = removed.class.is_translatable? ? removed.with_translations : removed
                        translation.send(association_id).delete to_remove
                      end if is_translatable?

                      # The translations of the removed item have to be also removed
                      # from this record's association
                      if removed.class.is_translatable?
                        record.send(association_id).delete removed.translations
                      end

                    end
                  end
                }
              )

              # Modifies the behaviour of :dependent option to take into account
              # translation-shared associations
              if reflection.macro == :has_many && is_translatable?
                reflection.configure_dependency_for_has_many_with_shared_translations
              end

              # Marker to avoid recursive redefinition
              initialize_translation_shared association_id

              # For has_many :throughs, the middle must have the same configuration
              # as the end
              if reflection.has_many_through_translatable?
                if reflection.is_translation_shared?
                  share_translations_for reflection.through_reflection.name
                elsif reflection.is_translation_shared_on_initialize?
                  initialize_translations_for reflection.through_reflection.name
                end
              end
            end

          end

        end

        # Reverses the action of +share_translations_for+
        def unshare_translations_for(*associations)
          options = associations.extract_options!
          associations.flatten.each do |association_id|
            if is_translation_shared_initialized? association_id
              reflections[association_id].mark_as_translation_shared(false, options)
              alias_method association_id, "#{association_id}_without_shared_translations"
              uninitialize_translation_shared association_id
            end
          end
        end

        # Reverses the action of +initialize_translations_for+
        def uninitialize_translations_for(*associations)
          unshare_translations_for associations, {:only_new => true}
        end

        # Given a reflection, will process the :translation_shared option
        def process_translation_shared reflection
          reset_translation_shared reflection.name
          if reflection.is_translation_shared?
            share_translations_for reflection.name
          end
        end

        # Returns the reflections that are translation_shared
        def translation_shared_reflections
          self.reflections.select do |name, reflection|
            reflection.is_translation_shared?
          end
        end

        # Returns the value for the var_name instance variable, or if this is nil,
        # follow the superclass chain to ask the value
        def instance_variable_inherited_get(var_name, method_name = nil)
          method_name ||= var_name
          value = instance_variable_get("@#{var_name}")
          if value.nil? && !@really_translatable_class && self.superclass.respond_to?(method_name)
            self.superclass.send(method_name)
          else
            value
          end
        end

        # Sets the value for the var_name instance variable, or if this is nil,
        # follow the superclass chain to set the value
        def instance_variable_inherited_set(value, var_name, method_name = nil)
          method_name ||= var_name
          if !@really_translatable_class && self.superclass.respond_to?(method_name)
            self.superclass.send(method_name, value)
          else
            instance_variable_set("@#{var_name}", value)
          end
        end

        # Returns true if the class is marked as translatable
        def is_translatable?
          instance_variable_inherited_get("translatable", "is_translatable?")
        end

        # Returns a list of translatable attributes for this class
        def translatable_attributes
          instance_variable_inherited_get("translatable_attributes")
        end

        # Returns the class that really calls the translatable method
        def really_translatable_class
          instance_variable_inherited_get("really_translatable_class")
        end

        # Returns true if this class is currently translating relations
        def is_translating_relations
          instance_variable_inherited_get("is_translating_relations")
        end

        # Sets the value of the is_translating_relations flag
        def is_translating_relations=(value)
          instance_variable_inherited_set(value, "is_translating_relations", "is_translating_relations=")
        end

        # Wrapper for translating relations preventing cyclical chain updates
        def translating_relations
          unless is_translating_relations
            self.is_translating_relations = true
            begin
              yield
            ensure
              self.is_translating_relations = false
            end
          end
        end

        # Returns true if the translatable propagation has been set to stop
        def stop_translatable_propagation
          instance_variable_inherited_get("stop_translatable_propagation")
        end

        # Setter for the stop_translatable_propagation_flag
        def stop_translatable_propagation=(value)
          instance_variable_inherited_set(value, "stop_translatable_propagation", "stop_translatable_propagation=")
        end

        # Returns true if the translation-shared association has been initialized
        def is_translation_shared_initialized? association_id = nil
          associations = initialized_translation_shared_list
          associations.is_a?(Array) && associations.include?(association_id)
        end

        # Returns the list of associations initialized
        def initialized_translation_shared_list
          instance_variable_inherited_get("initialized_translation_shared_list")
        end

        # Marks the association as initialized
        def initialize_translation_shared association_id
          new_association = Array(association_id)
          associations = instance_variable_inherited_get("initialized_translation_shared_list") || []
          associations +=  new_association
          instance_variable_inherited_set(associations, "initialized_translation_shared_list", "initialize_translation_shared")
        end

        # Unmarks the association as non-initialized (reverse of +initialize_translation_shared+)
        def uninitialize_translation_shared association_id
          initialized_associations = instance_variable_inherited_get("initialized_translation_shared_list") || []
          initialized_associations.delete(association_id)
        end

        # Unmarks an association as translation-shared initialized
        def reset_translation_shared association_id
          reset_association = Array(association_id)
          associations = instance_variable_inherited_get("initialized_translation_shared_list") || []
          associations -=  reset_association
          instance_variable_inherited_set(associations, "initialized_translation_shared_list", "reset_translation_shared")
        end

        # Applies the locale filter if needed, then performs the normal find method
        def find_with_locale_filter(*args)
          if self.is_translatable?
            options = args.extract_options!
            new_options = apply_locale_filter(options)
            find_without_locale_filter(args.first, new_options)
          else
            find_without_locale_filter(*args)
          end
        end

        # Applies the locale filter if needed, then performs the normal count method
        def count_with_locale_filter(*args)
          if self.is_translatable?
            options = args.extract_options!
            new_options = apply_locale_filter(options)
            count_without_locale_filter(args.first || :all, new_options)
          else
            count_without_locale_filter(*args)
          end
        end

        # When a scope is used, we save their find options inside a new,
        # unique key to avoid the loss of information that happens
        # when we merge scopes. We use later this information to easily
        # discriminate which conditions are to be applied in only one
        # translation or for all translations
        def with_scope_with_locale_filter(method_scoping = {}, action = :merge, &block)
          if (method_scoping[:find][:conditions] rescue false)
            method_scoping[:find][:unmerged_conditions] = method_scoping[:find][:conditions]
          end
          with_scope_without_locale_filter(method_scoping, action, &block)
        end


        # Attributes that are always 'translated' (not copied between languages)
        (@global_translatable_attributes ||= []) << :locale << :content_id

        # Used by third parties to add fields that should always
        # be independent between different languages
        def add_translatable_attributes(*args)
          @global_translatable_attributes += args
        end

        # Define scopes to limit the automatic update of common fields to instances
        # that have the same value for each scope (as a field name)
        @translatable_scopes ||= []

        # Used by third parties to add scopes for translations updates of common fields
        # It accepts two formats for condition:
        # - A String with a sql where condition (e.g. is_active = 1)
        # - A Proc that will be called with the current element argument and
        #   that should return a string (e.g. lambda{|el| "table.field = #{el.field + 1}"})
        def add_translatable_scope(condition)
          @translatable_scopes << condition
        end

        @@translatable_inheritable_instance_variables = %w{global_translatable_attributes translatable_scopes}

        ASSOCIATION_TYPES = %w{ has_one belongs_to has_many has_and_belongs_to_many }

        def self.extended(klass)
          # Ensure that the needed variables are inherited
          @@translatable_inheritable_instance_variables.each do |inheritable|
            unless eval("@#{inheritable}").nil?
              klass.instance_variable_set("@#{inheritable}", eval("@#{inheritable}").dup)
            end
          end

          # Aliases the find and count methods to apply the locale filter
          klass.class_eval do
            class << self
              alias_method_chain :find, :locale_filter
              alias_method_chain :count, :locale_filter
              alias_method_chain :with_scope, :locale_filter
              VALID_FIND_OPTIONS << :locale_list << :unmerged_conditions
            end
          end

          # Accept the :translation_shared option when defining associations
          ASSOCIATION_TYPES.each do |type|
            klass.send("valid_keys_for_#{type}_association") << :translation_shared
          end
        end

        def inherited(klass)
          super
          @@translatable_inheritable_instance_variables.each do |inheritable|
            unless eval("@#{inheritable}").nil?
              klass.instance_variable_set("@#{inheritable}", eval("@#{inheritable}").dup)
            end
          end
        end

        def clear_validation identifier
          self.validate.delete_if do |v|
            v.identifier == identifier
          end if self.validate.respond_to?(:delete_if)
        end

        def uniqueness_per_entity_validation_identifier
          :locale_uniqueness_per_entity
        end

        def clear_locale_uniqueness_per_entity_validation
          clear_validation uniqueness_per_entity_validation_identifier
        end

        # Assure no duplicated objects for the same locale
        def add_locale_uniqueness_per_entity_validation
          validates_uniqueness_of(
            :locale,
            :identifier => uniqueness_per_entity_validation_identifier,
            :scope => :content_id,
            :case_sensitive => false,
            :message => Proc.new { |*attrs|
              locale = attrs.last[:value] rescue false
              humanized_locale = Locale.find_by_iso_code(locale.to_s)
              humanized_locale = humanized_locale.native_name if humanized_locale
              I18n.t(
                'ubiquo.i18n.locale_uniqueness_per_entity',
                :model => self.human_name,
                :object_locale => humanized_locale
              )
            }
          )
        end

        private

        # This method is the one that actually applies the locale filter
        # This means that if you use .locale(..), you'll end up here,
        # when the results are actually delivered (not in call time)
        # Returns a hash with the resulting +options+ with the applied filter
        def apply_locale_filter(options)
          locales = really_translatable_class.instance_variable_get(:@current_locale_list)
          # set this find as dispatched
          really_translatable_class.instance_variable_set(:@current_locale_list, [])
          if locales.present?
            # build locale restrictions
            locales = merge_locale_list locales.reverse!
            locale_options = locales.extract_options!
            all_locales = locales.delete(:all)

            # add untranslatable instances if necessary
            locales << :any unless all_locales || locales.size == 0

            if all_locales
              locale_conditions = ""
            else
              locale_conditions = ["#{self.table_name}.locale in (?)", locales.map(&:to_s)]
              # act like a normal condition when we are just filtering a locale
              if locales.size == 2 && locales.include?(:any) && locale_options[:strict]
                new_options = options.merge(:conditions => merge_conditions(options[:conditions], locale_conditions))
                return new_options
              end
            end
            # locale preference order
            tbl = self.table_name
            locales_string = locales.size > 0 ? (["#{tbl}.locale != ?"]*(locales.size)).join(", ") : nil
            locale_order = ["#{tbl}.content_id", locales_string].compact.join(", ")

            current_includes = merge_includes(scope(:find, :include), options[:include])
            dependency_class = ::ActiveRecord::Associations::ClassMethods::JoinDependency
            join_dependency = dependency_class.new(self, current_includes, options[:joins])
            joins_sql = join_dependency.join_associations.collect{|join| join.association_join }.join
            # at this point, joins_sql in fact only includes the joins coming from options[:include]
            add_joins!(joins_sql, options[:joins])
            add_conditions!(conditions_sql = '', options[:conditions], scope(:find))
            conditions_sql.sub!('WHERE', '')

            conditions_tables = tables_in_string(conditions_sql)
            references_other_tables = conditions_tables.size > 1 || conditions_tables.first != self.table_name
            if references_other_tables
              mixed_conditions = merge_conditions(*other_table_conditions(options[:conditions]))
              own_conditions = merge_conditions(*same_table_conditions(options[:conditions]))
            end

            # now construct the subquery
            if locale_conditions.present?
              sql_locale_conditions = merge_conditions(locale_conditions, '')
            end

            from_and_joins = "FROM #{tbl} " + joins_sql.to_s

            adapters_with_custom_sql = %w{PostgreSQL MySQL}
            current_adapter = connection.adapter_name
            if adapters_with_custom_sql.include?(current_adapter)

              # Certain adapters support custom features that allow the locale
              # filter to do its job in a single sql. We use them for efficiency
              # In these cases, the subquery that will be build must respect
              # includes, joins and conditions from the original query
              # Note: all this is crying for a refactoring


              subfilter = case locale_options[:mode]
              when :strict
                all_conditions = merge_conditions(conditions_sql, sql_locale_conditions)
                from_and_joins + (all_conditions.present? ? "WHERE #{all_conditions}" : '')
              when :mixed
                content_id_query = from_and_joins
                content_id_query << "WHERE #{conditions_sql}" if conditions_sql.present?
                id_extra_cond = sql_locale_conditions.present? ? "#{sql_locale_conditions} AND" : ''
                new_options = options.merge(:conditions => nil, :joins => nil)
                scope(:find)[:conditions] = nil
                scope(:find)[:joins] = nil
                "FROM #{tbl} WHERE #{id_extra_cond} #{tbl}.content_id IN ("+
                    "SELECT #{tbl}.content_id #{content_id_query})"
              else
                # Default. Only search for matches in translations in associations
                if references_other_tables
                  content_id_query = from_and_joins
                  content_id_query << "WHERE #{mixed_conditions}" unless mixed_conditions.blank?
                  id_extra_cond = merge_conditions(own_conditions, sql_locale_conditions)
                  id_extra_cond += ' AND' if id_extra_cond.present?

                  new_options = options.merge(:conditions => own_conditions, :joins => nil)
                  scope(:find)[:conditions] = nil
                  scope(:find)[:joins] = nil
                  "FROM #{tbl} WHERE #{id_extra_cond} #{tbl}.content_id IN ("+
                       "SELECT #{tbl}.content_id #{content_id_query})"
                else
                  # No associations involved. Same as :strict. Needs a refactor!
                  all_conditions = merge_conditions(conditions_sql, sql_locale_conditions)
                  from_and_joins + (all_conditions.present? ? "WHERE #{all_conditions}" : '')
                end
              end

              locale_filter = case current_adapter
              when "PostgreSQL"
                # use a subquery with DISTINCT ON, more efficient, but currently
                # only supported by Postgres

                ["#{tbl}.id IN (" +
                    "SELECT DISTINCT ON (#{tbl}.content_id) #{tbl}.id " + subfilter +
                    "ORDER BY #{locale_order})", *locales.map(&:to_s)
                ]

              when "MySQL"
                # it's a "within-group aggregates" problem. We need to order before grouping.
                # This subquery is O(N * log N), while a correlated subquery would be O(N^2)

                ["#{tbl}.id IN (" +
                    "SELECT id FROM ( SELECT #{tbl}.id, #{tbl}.content_id " + subfilter +
                    "ORDER BY #{locale_order}) AS lpref " +
                    "GROUP BY content_id)", *locales.map(&:to_s)
                ]
              end

              # finally, merge the created subquery into the current conditions
              if new_options
                new_options[:conditions] = merge_conditions(new_options[:conditions], locale_filter)
              else
                new_options = options.merge(:conditions => merge_conditions(options[:conditions], locale_filter))
              end

            else
              # For the other adapters, the strategy is to do two subqueries.
              # This can be problematic for generic queries since we have to
              # suppress the paginator scope to guarantee the correctness (#254)

              # find the final IDs
              ids = nil

              # redefine after_find callback method avoiding its call with next find
              self.class_eval do
                def after_find_with_neutralize; end
                def after_initialize_with_neutralize; end
                alias_method_chain :after_find, :neutralize if self.instance_methods.include?("after_find")
                alias_method_chain :after_initialize, :neutralize if self.instance_methods.include?("after_initialize")
              end

              begin

                # removes paginator scope.
                with_exclusive_scope(:find => {:limit => nil, :offset => nil, :joins => nil, :include => nil}) do


                  conditions_for_id_query = case locale_options[:mode]
                  when :strict
                      merge_conditions(conditions_sql, sql_locale_conditions)
                  when :mixed
                        original_query = from_and_joins
                        joins_sql = nil # already applied
                        (original_query << "WHERE #{conditions_sql}") if conditions_sql.present?
                        extra_cond = sql_locale_conditions.present? ? "#{sql_locale_conditions} AND" : ''
                        "#{extra_cond} #{tbl}.content_id IN ("+
                            "SELECT #{tbl}.content_id #{original_query})"
                  else
                    # Default. Only search for matches in translations in associations
                    if references_other_tables
                      content_id_query = from_and_joins
                      content_id_query << "WHERE #{mixed_conditions}" unless mixed_conditions.blank?
                      joins_sql = nil # already applied
                      new_options = options.merge(:conditions => own_conditions, :joins => nil)
                      id_extra_cond = merge_conditions(own_conditions, sql_locale_conditions)
                      id_extra_cond += ' AND' if id_extra_cond.present?
                      "#{id_extra_cond} #{tbl}.content_id IN ("+
                          "SELECT #{tbl}.content_id #{content_id_query})"
                    else
                      # No associations involved. Same as :strict
                      merge_conditions(conditions_sql, sql_locale_conditions)
                    end
                  end

                  ids = find(:all, {
                      :select => "#{tbl}.id, #{tbl}.content_id ",
                      :order => sanitize_sql_for_conditions(["#{locale_order}", *locales.map(&:to_s)]),
                      :conditions => conditions_for_id_query,
                      :include => options[:include],
                      :joins => joins_sql
                  })
                end
              ensure
                # restore after_find callback method
                self.class_eval do
                  alias_method :after_find, :after_find_without_neutralize if self.instance_methods.include?("after_find")
                  alias_method :after_initialize, :after_initialize_without_neutralize if self.instance_methods.include?("after_initialize")
                end
              end

              #get only one ID per content_id
              content_ids = {}
              ids = ids.select{ |id| content_ids[id.content_id].nil? ? content_ids[id.content_id] = id : false }.map{|id| id.id.to_i}

              # these are already factored in the new conditions
              if scope(:find)
                scope(:find)[:conditions] = nil
                scope(:find)[:joins] = nil
              end

              if new_options
                new_options[:conditions] = merge_conditions(new_options[:conditions], {:id => ids})
              else
                new_options = options.merge(:conditions => {:id => ids})
              end
            end
          end
          # return the modified options, or the original ones if there is no change
          new_options || options
        end

        # returns an array with the sql conditions that refer to other trables
        def other_table_conditions(conditions)
          normalized_conditions(conditions) - same_table_conditions(conditions)
        end

        # returns an array with the sql conditions that refer to this model table
        def same_table_conditions(conditions)
          normalized_conditions(conditions).select{ |cond| cond =~ /\b#{table_name}.?\./ }
        end

        # returns an array of all the applicable sql conditions (given +conditions+ and the current scope)
        def normalized_conditions(conditions)
          scope_conditions = scoped_methods.map{|scoping| scoping[:find][:unmerged_conditions] rescue nil }.compact
          (scope_conditions + [conditions].compact).map{|condition| sanitize_sql(condition)}
        end

        def merge_locale_list locales
          merge_locale_list_rec locales.first, locales[1,locales.size]
        end

        def merge_locale_list_rec previous, rest
          new = rest.first
          return previous.clone unless new
          merged = if previous.empty? || previous.include?(:all)
            new
          else
            previous & new
          end
          merged = previous if merged.empty? && new.include?(:all)
          merge_locale_list_rec merged, rest[1,rest.size]
        end

      end

      module InstanceMethods

        def self.included(klass)
          klass.send :before_validation, :initialize_i18n_fields
          klass.alias_method_chain :update, :translatable
          klass.alias_method_chain :create, :translatable
          klass.alias_method_chain :create, :i18n_fields
        end

        def is_association_initialized?(association)
          self.instance_variable_get("@#{association}_initialized")
        end

        def association_initialized!(association)
          self.instance_variable_set("@#{association}_initialized", true)
        end

        # proxy to add a new content_id if empty on creation
        def create_with_i18n_fields
          initialize_i18n_fields
          create_without_i18n_fields
        end

        def initialize_i18n_fields
          if self.class.is_translatable?
            # we do this even if there is not currently any tr. attribute,
            # as long as is a translatable model
            unless self.content_id
              self.content_id = self.class.connection.next_val_sequence("#{self.class.table_name}_$_content_id")
            end
            unless self.locale
              self.locale = Locale.current
            end
          end
        end

        # When cloning a object do not copy the content_id
        def clone_with_i18n_fields_ignore
          clone = clone_without_i18n_fields_ignore
          clone.content_id = nil if self.class.is_translatable?
          clone
        end

        def attributes_with_i18n_fields_assignement_advancement=(attributes, guard_protected_attributes = true)
          if self.class.is_translatable?
            fields_to_populate = %w{locale content_id}
            attributes_to_apply = attributes.select { |key, value| fields_to_populate.include?(key.to_s) }
            attributes_to_apply.each do |key, value|
              write_attribute key.to_sym, value
            end
          end
          send("attributes_without_i18n_fields_assignement_advancement=", attributes, guard_protected_attributes)
        end

        # Whenever we update existing content or create a translation, the expected behaviour is the following
        # - The translatable fields will be updated just for the current instance
        # - Fields not defined as translatable will need to be updated for every instance that shares the same content_id
        def create_with_translatable
          replace_belongs_to_ids_with_self_locale
          saved = create_without_translatable
          if saved
            update_foreign_keys_with_new_translation_id
            update_translations
          end
          saved
        end

        def update_with_translatable
          replace_belongs_to_ids_with_self_locale
          saved = update_without_translatable
          update_translations if saved
          saved
        end

        def update_translations
          if self.class.is_translatable? && !@stop_translatable_propagation
            # prepare "self" to be the relations model for its translations
            self.prepare_for_shared_translations
            # Update the translations
            self.translations.each do |translation|
              translation.without_updating_translations do
                translation.update_attributes untranslatable_attributes
                translation.copy_translatable_shared_relations_from self
              end
            end
          end
        end

        # When an instance is going to be saved, replace its belongs_to ids
        # with the ones of instances in the same locale than the instances.
        # This avoids queries in the future and the DB is kept in a more intuitive state
        def replace_belongs_to_ids_with_self_locale
          return unless self.class.is_translatable?
          self.class.translating_relations do
            self.class.translation_shared_reflections.each do |name, reflection|
              if reflection.macro == :belongs_to
                refresh_reflection_value_if_needed(reflection)
                current = send("#{reflection.name}_without_shared_translations")
                if current && current.class.is_translatable? && !current.in_locale?(self.locale)
                  if current_in_my_locale = current.in_locale(self.locale)
                    send("#{name}=", current_in_my_locale)
                  end
                end
              end
            end
          end
        end

        # When an instance is first saved, update the translation_shared relations
        # that should now point to it
        def update_foreign_keys_with_new_translation_id
          return unless self.class.is_translatable?
          self.class.translating_relations do
            self.class.translation_shared_reflections.each do |name, reflection|
              next if reflection.options[:through]
              unless reflection.macro == :belongs_to
                # if this association was not loaded, we reset it after the work, else it's confusing to the user
                original_association = self.send("#{name}_without_shared_translations")
                reset = original_association && !original_association.loaded?
                without_current_locale(self.locale) do
                  [self.send(name)].flatten.compact.each do |record|
                    if record.class.is_translatable? && record.in_locale?(self.locale) && record.send(reflection.primary_key_name) != self.class.primary_key
                      record.without_updating_translations do
                        record.update_attribute reflection.primary_key_name, send(self.class.primary_key)
                      end
                    end
                  end
                  if reset && original_association.respond_to?(:reset)
                    original_association.reset
                  elsif
                    # has_ones have no interface to do a lazy reset other than this.
                    association_instance_set(name, nil)
                  end
                end
              end
            end
          end
        end

        def alert_translation_shared_not_supported(association_id, klass)
          raise "You are trying to share translations in :#{association_id} of #{self.class}. " +
            "This behaviour can't be supported by ubiquo_i18n. Either use a has_many :through " +
            "with an intermediate translatable model, or mark the #{klass} model as translatable"
        end

        # If we don't have a current locale and we aren't in a translatable instance,
        # there is nothing we can do to share.
        # Also, if the reflection is not marked as shared we should do nothing.
        def applicable_translation_shared reflection
          (Locale.current || self.class.is_translatable?) && reflection.is_translation_shared?(self)
        end

        # Returns whether +association+ has been already loaded
        def cached_translation_shared_association(association)
          association_loaded?(association) && !locale_changed_from_load_time?(association)
        end

        # Returns whether the current locale has changed from the (possible) moment
        # that +association+ was loaded.
        def locale_changed_from_load_time?(association)
          # AssociationProxy has most of the basic methods removed, including
          # instance_variable_get, so the following line will in fact load the target.
          association.instance_variable_get(:@loaded_in_locale) != Locale.current
        end

        # Provides an unified interface to know if +association+ has been loaded.
        # Rails has different mechanisms for single and collection associations,
        # this method will work for all them.
        def association_loaded?(association)
          association.respond_to?(:loaded?) && association.loaded?
        end

        def untranslatable_attributes_names
          translatable_attributes = (self.class.translatable_attributes || []) +
            (self.class.instance_variable_get('@global_translatable_attributes') || []) +
            (self.class.reflections.select do |name, ref|
                ref.macro != :belongs_to ||
                !ref.is_translation_shared? ||
                ((model = [send(name)].first) && model.class.is_translatable?)
            end.map{|name, ref| ref.primary_key_name})
          attribute_names - translatable_attributes.map{|attr| attr.to_s}
        end

        def untranslatable_attributes
          attrs = {}
          (untranslatable_attributes_names + ['content_id'] - ['id']).each do |name|
            attrs[name] = clone_attribute_value(:read_attribute, name)
          end
          attrs
        end

        # Returns true if the primary_key for +reflection+ has been changed, and it was not nil before
        def has_updated_existing_primary_key reflection
          send("#{reflection.primary_key_name}_changed?") && send("#{reflection.primary_key_name}_was")
        end

        def attributes_except_unique_for_translation
          attributes.reject{|attr, value| [:id, :locale].include?(attr.to_sym)}
        end

        # Used to execute a block disabling automatic translation update for this instance
        def without_updating_translations
          previous_value = @stop_translatable_propagation
          @stop_translatable_propagation = true
          begin
            yield
          ensure
            @stop_translatable_propagation = previous_value
          end
        end

        # Execute a block without being affected by any possible current locale
        def without_current_locale loc = nil
          begin
            @current_locale, Locale.current = Locale.current, loc if Locale.current
            yield
          ensure
            Locale.current = @current_locale
          end
        end

      end

    end
  end
end
