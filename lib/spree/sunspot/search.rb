require 'spree/core/search/base'
require 'spree/sunspot/filter/filter'
require 'spree/sunspot/filter/condition'
require 'spree/sunspot/filter/param'
require 'spree/sunspot/filter/query'

module Spree
  module Sunspot
    class Search < Spree::Core::Search::Base

      def solr_search
        @solr_search
      end

      def retrieve_products(featured = 0, paginate = true, boosts = nil)
        if boosts.nil?
          boosts = {
            # :group => 4.0,                
            # :name => 2.0,
            # :theme => 1.0,
            # :for => 1.0,
            # :material => 1.0,
            # :saletype => 1.0,
            # :pattern => 1.0,
            # :brand => 1.0,
            # :size => 1.0,
            # :shape => 1.0,
            # :color => 1.0,
            # :description => 0.8,
            # :category => 0.5,
            # :type => 0.5,
          }
        end
        @solr_search =  ::Sunspot.new_search(Spree::Product) do |q|

          # Full text search
          unless @term.nil?
            field_term = @term.split(' ').select{|t|!["party"].include?(t)}.join(' ')
            q.fulltext(field_term) do
              fields(
                :category,
                :group,
                :type,
                :name,
                :theme,
                :gender,
                :pattern,
                :color,
                :material,
                :size,
                :brand,
                :taxon,
                :related_taxons,
                :shape
              )
              boost_fields(boosts)
              minimum_match 1
            end
          end

          # Add facets
          list = [:category,:group,:type,:theme,:color,:shape,:brand,:size,:material,:saletype,:pattern,:gender]
          list.each do |facet|
            q.facet(facet)
          end

          # Filter results
          q.with(:is_active, true)
          if @properties[:price].present? then
            low = @properties[:price].first
            high = @properties[:price].last
            q.with(:price,low..high)
          end
          if featured > 0 then
            q.with(:featured, 1)          
          end
          
          # Order results
          unless @term.nil?
            q.order_by(:score, :desc)
          end
          q.order_by(:in_stock, :desc)
          q.order_by(:missing_image)          
          q.order_by(:theme)
          q.order_by(:position)
          q.order_by(:subposition)
          unless @properties[:order_by].empty?
            sort = @properties[:order_by].split(',')
            q.order_by(sort[0],sort[1])
          end

          # Paginate
          if paginate
            q.paginate(:page => @properties[:page] || 1, :per_page => @properties[:per_page] || Spree::Config[:products_per_page])
          else
            q.paginate(:page => @properties[:page] || 1, :per_page => 1000) # Could do Spree::Product.count, but we'll save the query and just assume 1000
          end
        end

        # Add filter queries based on url params
        unless @properties[:filters].blank?
          conditions = Spree::Sunspot::Filter::Query.new( @properties[:filters] )
          @solr_search = conditions.build_search( @solr_search )
        end

        @solr_search.execute

        @solr_search.hits

      end

      def retrieve_related(theme)

        @related =  ::Sunspot.new_search(Spree::Product) do |q|

          q.with(:is_active, true)

          q.with(:related,theme.to_s)

          q.order_by(:missing_image)
          q.order_by(:in_stock, :desc)


          unless @properties[:order_by].empty?
            sort = @properties[:order_by].split(',')
            q.order_by(sort[0],sort[1])
          end


          q.order_by(:theme)

          q.order_by(:position)
          q.order_by(:subposition)

          q.paginate(:page => 1, :per_page => 1000)

        end

        @related.execute

        @related.hits

      end

      def groups(category)

        @solr_search =  ::Sunspot.new_search(Spree::Product) do |q|

          #list = [:category,:group,:type,:theme,:color,:shape,:brand,:size,:material,:for,:agegroup]
          #list.each do |facet|
          q.facet(:group, :limit => -1)
          #end

          q.with(:is_active, true)
          q.with(:category, category)
          q.keywords(keywords)

          unless @properties[:order_by].empty?
            sort = @properties[:order_by].split(',')
            q.order_by(sort[0],sort[1])
          end


          q.order_by(:position)
          q.order_by(:subposition)

          if @properties[:price].present? then
            low = @properties[:price].first
            high = @properties[:price].last
            q.with(:price,low..high)
          end

          q.paginate(:page => @properties[:page] || 1, :per_page => @properties[:per_page] || Spree::Config[:products_per_page])

        end


        unless @properties[:filters].blank?
          conditions = Spree::Sunspot::Filter::Query.new( @properties[:filters] )
          @solr_search = conditions.build_search( @solr_search )
        end

        @solr_search.execute

        @solr_search.facets.first.rows

      end

      def similar_products(product, *field_names)
        products_search = ::Sunspot.more_like_this(product) do
          fields *field_names
          boost_by_relevance true
          paginate :per_page => total_similar_products * 4, :page => 1
        end

        # get active, in-stock products only.
        base_scope = get_common_base_scope
        hits = []
        if products_search.total > 0
          hits = products_search.hits.collect{|hit| hit.primary_key.to_i}
          base_scope = base_scope.where( ["#{Spree::Product.table_name}.id in (?)", hits] )
        else
          base_scope = base_scope.where( ["#{Spree::Product.table_name}.id = -1"] )
        end
        products_scope = @product_group.apply_on(base_scope)
        products_results = products_scope.includes([:images, :master]).page(1)

        # return top N most-relevant products (i.e. in the same order returned by more_like_this)
        @similar_products = products_results.sort_by{ |p| hits.find_index(p.id) }.shift(total_similar_products)
      end

      def intercept

        return {} unless keywords

        #search keywords for matches in taxon names
        # Spree::Taxon.all(:order => 'length(name) desc, name').each do |cat|
        #   if key.include? cat.name then
        #     redirect.update(:permalink => cat)
        #     key = key.gsub(cat.name,'')
        #     break
        #   end
        # end


        #select facets for
        # matches = [:category, :group, :type, :theme, :keyword, :color, :shape, :size, :pattern, :count]
        # @facet_match = ::Sunspot.new_search(Spree::Product) do |q|

        #   matches.sort_by(&:length).reverse.each do |facet|
        #     q.facet facet, :limit => -1, :sort => :count
        #   end
        #   q.paginate(page: 1, per_page: Spree::Product.count)

        # end


        # @facet_match.execute

        # @facet_match.hits.each do |hit|
        #   if hit.stored(:sku) == keywords.upcase then
        #     return {:product => hit }
        #   end
        # end

        # matches.each do |face|
        #   @facet_match.facet(face).rows.each do |row|
        #     if key.match("\\b#{row.value}\\b") then
        #       key = key.gsub(row.value,'')
        #       redirect.update(face => row.value)
        #     elsif key.match("\\b#{row.value.singularize}\\b")
        #       key = key.gsub(row.value.singularize,'')
        #       redirect.update(face => row.value)
        #     end
        #   end
        # end

        # Redirect to product on sku match
        product_match = Spree::Product.joins(:master).where("spree_variants.sku = ?", keywords).take(1)
        unless product_match.nil? || product_match.empty?
          return {:product => product_match[0]}
        end

        # redirect.update(:keywords => key.strip.split.join(' ')) unless key.strip.empty?
        # params["q"] = keywords

        {}
      end

      protected

      def get_base_scope
        base_scope = Spree::Product.active
        base_scope = base_scope.in_taxon(taxon) unless taxon.blank?
        base_scope = get_products_conditions_for(base_scope, keywords)

        base_scope = add_search_scopes(base_scope)
      end



      # TODO: This method is shit; clean it up John. At least you were paid to write this =P
      def get_products_conditions_for(base_scope, query)
        @solr_search = ::Sunspot.new_search(Spree::Product) do |q|
          q.keywords(query)

          q.order_by(
              ordering_property.flatten.first,
              ordering_property.flatten.last)
          # Use a high per_page here so that all results are retrieved when setting base_scope at the end of this method.
          # Otherwise you'll never have more than the first page of results from here returned, when pagination is done
          # during the retrieve_products method.
          q.paginate(page: 1, per_page: Spree::Product.count)
        end

        unless @properties[:filters].blank?
          conditions = Spree::Sunspot::Filter::Query.new( @properties[:filters] )
          @solr_search = conditions.build_search( @solr_search )
        end

        @solr_search.build do |query|
          build_facet_query(query)
        end

        @solr_search.execute
        if @solr_search.total > 0
          @hits = @solr_search.hits.collect{|hit| hit.primary_key.to_i}
          base_scope = base_scope.where( ["#{Spree::Product.table_name}.id in (?)", @hits] )
        else
          base_scope = base_scope.where( ["#{Spree::Product.table_name}.id = -1"] )
        end

        base_scope
      end

      def prepare(params)
        super
        @term = params[:keywords]

        filter = {}
        filter = {:taxon_ids => taxon.self_and_descendants.map(&:id) + taxon.related_ids} unless taxon.class == NilClass

        list = [:category,:group,:type,:theme,:color,:shape,:brand,:size,:material,:for,:saletype,:keyword,:pattern,:supplements,:gender]
        list.each do |prop|
          filter.update(prop.to_s => params[prop.to_s].split(',')) unless !params[prop.to_s].present?
        end

        #if @properties[:taxon].respond_to?(:id)
        #filter.update(:taxon_ids => [@properties[:taxon][:id].to_s])
        #end
        filter.merge!(params[:s]) unless !params[:s].present?

        @properties[:filters] = filter

        @properties[:price] = params[:price].split('-') if params[:price].present?
        @properties[:order_by] = params[:order_by] || params['order_by'] || []
        @properties[:total_similar_products] = params[:total_similar_products].to_i > 0 ?
            params[:total_similar_products].to_i :
            Spree::Config[:total_similar_products]
      end

      def build_facet_query(query)
        Setup.query_filters.filters.each do |filter|
          if filter.values.any? && filter.values.first.is_a?(Range)
            query.facet(filter.search_param) do
              filter.values.each do |value|
                row(value) do
                  with(filter.search_param, value)
                end
              end
            end
          else
            query.facet(
                filter.search_param,
                exclude: property_exclusion( filter.exclusion )
            )
          end
          # Temporary hack to allow for geodistancing
          unless @properties[:location_coords].nil?
            coords = @properties[:location_coords].split(',')
            coords.flatten
            lat = coords[0]
            long = coords[1]
            query.with(:location).in_radius( lat, long, 50 )
          end
        end
      end

      def property_exclusion(filter)
        return nil if filter.blank?
        prop = @properties[:filters].select{ |f| f == filter.to_s }
        prop[filter] unless prop.empty?
      end

      def ordering_property
        @properties[:order_by] = @properties[:order_by].blank? ? %w(score desc) : @properties[:order_by].split(',')
        @properties[:order_by].flatten
      end

    end
  end
end
