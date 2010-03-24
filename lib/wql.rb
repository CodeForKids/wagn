=begin

# this one sucks:
select type, name, 
(
  select count(*) from cards    
  WHERE cards.trash='f' AND cards.id in (
    select trunk_id from cards    
    WHERE cards.trash='f' AND cards.tag_id in (
      select id from cards WHERE cards.trash='f' AND cards.id=t0.id
    )   
  ) 
) as count 
from cards t0 order by count desc limit 10;

  
# this one works:
  
 select id, trunk_id, created_at, value, updated_at, current_revision_id, name, type, extension_id, extension_type, sealed, created_by, updated_by, priority, plus_sidebar, reader_id, writer_id, reader_type, writer_type, old_tag_id, tag_id, key, trash, appender_type, appender_id, indexed_content, indexed_name, count(*) 
 from cards join cards c2 on c2.tag_id=cards.id 
 group by cards.*
 order by count(*) desc limit 10;  
  
=end

class Wql    
  ATTRIBUTES = {
    :basic=> %w{ name type content id key extension_type extension_id },
    :system => %w{ trunk_id tag_id },
    :semi_relational=> %w{ edited_by edited member_of member role found_by },
    :relational => %w{ part left right plus left_plus right_plus },  
    :referential => %w{ link_to linked_to_by refer_to referred_to_by include included_by },
    :special => %w{ or match complete not count and },
    :ignore => %w{ prepend append },
    :pass => %w{ cond }
  }.inject({}) {|h,pair| pair[1].each {|v| h[v.to_sym]=pair[0] }; h }
  # put into form: { :content=>:basic, :left=>:relational, etc.. }

  OPERATORS = %w{ != = =~ < > in ~ }.inject({}) {|h,v| h[v]=nil; h }.merge({
    'eq' => '=',
    'gt' => '>',
    'lt' => '<',
    'match' => '~',
    'ne' => '!=',
    'not in' => nil,
  }.stringify_keys)
  
  MODIFIERS = {
    :sort   => "",
    :dir    => "",
    :limit  => "",
    :offset => "",  
#    :group_tagging  => "",
    :return => :list,
    :join   => :and,
    :view   => nil    # handled in interface-- ignore here
  }
      
  DEFAULT_ORDER_DIRS =  {
    "update" => "desc",
    "create" => "asc",
    "alpha" => "asc", # DEPRECATED
    "name" => "asc",
    "content" => "asc",
    #"plusses" => "desc",
    "relevance" => "desc"
  }

  cattr_reader :root_perms_only
  @@root_perms_only = false

  def self.without_nested_permissions
    @@root_perms_only = true
    result = yield
    @@root_perms_only = false
    result
  end
    
  def initialize query
    @cs = CardSpec.build( query )
  end
  
  def query
    @cs.query
  end
  
  def sql
    @cs.to_sql
  end
  
  def run
    if query[:return] == "name_content"
      ActiveRecord::Base.connection.select_all( sql ).inject({}) do |h,x|
        h[x["name"]] = x["content"]; h
      end
    else
      results = Card.find_by_sql( sql )
      if query[:prepend] || query[:append]
        results = results.map do |card|             
          CachedCard.get [query[:prepend], card.name, query[:append]].compact.join('+')
        end
      end
      results
    end
  end
  
  class Spec 
    attr_accessor :spec
    
    def walk(spec, method)
      case 
        when spec.respond_to?(method); spec.send(method)
        when spec.is_a?(Hash); spec.inject({}) {|h,p| h[p[0]] = walk(p[1], method); h }
        when spec.is_a?(Array); spec.collect {|v| walk(v, method) }
        else spec
      end
    end
    
    def walk_spec() walk(@spec, :walk_spec); end     
    
    def quote(v)
      ActiveRecord::Base.connection.quote(v) 
    end
    
    def match_prep(v,cardspec=self)
      cxn ||= ActiveRecord::Base.connection
      v=cardspec.root.params['_keyword'] if v=='_keyword'
      v.strip!
      [cxn, v]
    end
  end
  

  class SqlCond < String
    def to_sql(*args)
      self
    end
  end
  
  class SqlStatement
    attr_accessor :fields, :joins, :conditions, :tables, :order, :limit, :offset,
      :relevance_fields, :count_fields, :group
    
    def initialize
      self.fields, self.joins, self.conditions, self.count_fields, self.relevance_fields = [],[],[],[],[]
      self.tables, self.order, self.limit, self.group, self.offset = "","","","",""
    end
    
    def to_s
      "(select #{fields.reject(&:blank?).join(', ')} from #{tables} #{joins.join(' ')} " + 
        "where #{conditions.reject(&:blank?).join(' and ')} #{group} #{order} #{limit} #{offset})"
    end 
  end

  class CardSpec < Spec 
    attr_reader :params, :sql, :query
    
    class << self
      def build(query)
        cardspec = self.new(query)
        cardspec.merge(cardspec.spec)         
      end
    end 
     
    def initialize(query)   
      # NOTE:  when creating new specs, make sure to specify _parent *before*
      #  any spec which could trigger another cardspec creation further down.
      @mods = MODIFIERS.clone
      @params = {}   
      @selfname, @parent = nil, nil
      #warn("<br>before clean #{(Hash===spec ? spec : spec.spec).keys}<br>")
      @query = clean(query.clone)
      @spec = @query.deep_clone
      #warn("after clean #{@spec.inspect}<br>")
      
      @sql = SqlStatement.new
      self
    end
    
    def table_alias 
      case
        when @mods[:return]==:condition;   @parent ? @parent.table_alias : "t"
        when @parent; @parent.table_alias + "x" 
        else "t"  
      end
    end
    
    def root
      @parent ? @parent.root : self
    end
    
    def root?
      root == self
    end
    
    def selfname   
      @selfname #|| raise(Wagn::WqlError, "_self referenced but no card is available")
    end
    
#   def to_card(relative_name)
#     case relative_name
#     when "_self";  root.card                                   
#     when "_left";  CachedCard.get(root.card.name.parent_name)
#     when "_right"; CachedCard.get(root.card.name.tag_name)
#     end
#   end
    
    def absolute_name(name)
      name = (root.selfname ? name.to_absolute(root.selfname) : name)
    end
    
    def clean(query)
      query = query.symbolize_keys

      query.each do |key,val|
        case key.to_s
        when '_self'    ; @selfname         = query.delete(key)
        when '_parent'  ; @parent           = query.delete(key) 
        when /^_\w+$/   ; @params[key.to_s] = query.delete(key)
        end
      end
      
      query.each{ |key,val| clean_val(val, query, key) } #must be separate loop to make sure card values are set
      query
    end
    
    def clean_val(val, query, key)
      query[key] =
        case val
        when String ; val.empty? ? val : absolute_name(val)
        when Hash   ; clean(val)
        when Array  ; val.map{ |v| clean_val(v, query, key)}
        else        ; val
        end
    end
    
    def merge(spec)
      # string or number shortcut    
      #warn "#{self}.merge(#{spec.inspect})"
      
      spec = case spec
#        when /^_(self|left|right)$/;  { :id => to_card(spec).id }                                   
        when String;   { :key => spec.to_key }
        when Integer;  { :id  => spec }  
        when Hash;     spec
        else raise("Invalid cardspec args #{spec.inspect}")
      end

      spec.each do |key,val| 
        if key == :_parent
          @parent = spec.delete(key) 
        elsif OPERATORS.has_key?(key.to_s) && !ATTRIBUTES[key]
          spec.delete(key)
          spec[:content] = [key,val]
        elsif MODIFIERS.has_key?(key)
          # match datatype to default
          case @mods[key]
            when String;  @mods[key] = spec.delete(key).to_s
            when Symbol;  @mods[key] = spec.delete(key).to_sym
            else @mods[key] = spec.delete(key)
          end
        end
      end
      
      # process conditions
      spec.each do |key,val| 
        case ATTRIBUTES[key]
          when :basic; spec[key] = ValueSpec.new(val, self)
          when :system; spec[key] = val.is_a?(ValueSpec) ? val : subspec(val)
          when :relational, :semi_relational, :plus, :special; self.send(key, spec.delete(key))    
          when :referential;  self.refspec(key, spec.delete(key))
          when :ignore; spec.delete(key)
          when :pass; # for :cond  ie. raw sql condition to be ANDed
          else raise("Invalid attribute #{key}") unless key.to_s.match(/(type|id)\:\d+/)
        end                      
      end
      
      @spec.merge! spec  
      self
    end          
    
    def found_by(val)
      cards = (String===val ? [CachedCard.get(absolute_name(val))] : Card.search(val))
      cards.each do |c|
        raise %{"found_by" value needs to be valid Search card #{c.inspect}} unless c && ['Search','Set'].include?(c.type)
        found_by_spec = CardSpec.new(c.get_spec).spec
        merge(field(:id) => subspec(found_by_spec))
      end
    end
    
    def match(val)
      cxn, v = match_prep(val)
      v.gsub!(/\W+/,' ')
      
      cond =
        if System.enable_postgres_fulltext
          v = v.strip.gsub(/\s+/, '&')
          sql.relevance_fields << "rank(indexed_name, to_tsquery(#{quote(v)}), 1) AS name_rank"
          sql.relevance_fields << "rank(indexed_content, to_tsquery(#{quote(v)}), 1) AS content_rank"
          "indexed_content @@ to_tsquery(#{quote(v)})" 
        else
          sql.joins << "join revisions r on r.id=#{self.table_alias}.current_revision_id"
          # FIXME: OMFG this is ugly
          '(' + ["replace(#{self.table_alias}.name,'+',' ')",'r.content'].collect do |f|
            v.split(/\s+/).map{ |x| %{#{f} #{cxn.match(quote("[[:<:]]#{x}[[:>:]]"))}} }.join(" AND ")
          end.join(" OR ") + ')'
        end
      merge :cond=>SqlCond.new(cond)
    end
    
    def complete(val)
      no_plus_card = (val=~/\+/ ? '' : "and tag_id is null")  #FIXME -- this should really be more nuanced -- it breaks down after one plus
      merge :cond => SqlCond.new(" lower(name) LIKE lower(#{quote(val.to_s+'%')}) #{no_plus_card}")
    end

    def field(name)
      @fields||={}; @fields[name]||=0; @fields[name]+=1
      "#{name}:#{@fields[name]}"
    end

    #def type(val)
    #  merge field(:type) => subspec(val, { :return=>:codename })
    #end
    
    def cond(val); #noop      
    end
    
    def and(val)
      merge val
    end
    
    def or(val)
      merge :cond => CardSpec.build(:join=>:or, :return=>:condition, :_parent=>self).merge(val)
    end
    
    def not(val)
      merge field(:id) => subspec(val, { :return=>'id' }, negate=true)
    end

    def left(val)
      merge field(:trunk_id) => subspec(val)
    end

    def right(val)
      merge field(:tag_id) => subspec(val)
    end
    
    def part(val) 
      merge :or=>{ :tag_id => val, :trunk_id => val }
    end  
    
    def right_plus(val) 
      part_spec, connection_spec = val.is_a?(Array) ? val : [ val, {} ]
      merge( field(:id) => subspec(connection_spec, :return=>'trunk_id', :tag_id=> part_spec ))
    end                                                                                                
    
    def left_plus(val)
      part_spec, connection_spec = val.is_a?(Array) ? val : [ val, {} ]
      merge( field(:id) => subspec(connection_spec, :return=>'tag_id', :trunk_id=>part_spec))      
    end    

    def plus(val)
      #warn "GOT PLUS: #{val}"
      part_spec, connection_spec = val.is_a?(Array) ? val : [ val, {} ]
      merge :or=>{
        field(:id) => subspec(connection_spec, :return=>'trunk_id', :tag_id=>part_spec.clone),
        field(:id) => subspec(connection_spec, :return=>'tag_id', :trunk_id=>part_spec)
      }
    end          
    
    def edited_by(val)
      #user_id = ((c = Card::User[val]) ? c.extension_id : 0)
      extension_select = CardSpec.build(:return=>'extension_id', :extension_type=>'User', :_parent=>self).merge(val).to_sql
      sql.joins << "join (select distinct card_id from revisions r " +
        "where created_by in #{extension_select} ) ru on ru.card_id=#{table_alias}.id"
    end
    
    def edited(val)
      inner_spec = CardSpec.build(:return=>'ru.created_by', :_parent=>self).merge(val)
      inner_spec.sql.joins << "join (select distinct card_id, created_by from revisions r  ) ru on ru.card_id=#{inner_spec.table_alias}.id"
      
      merge({
        :extension_id => ValueSpec.new(['in',inner_spec],self),
        :extension_type => 'User'
      })
    end
    
    def member_of(val)
      inner_spec = CardSpec.build(:return=>'ru.user_id', :extension_type=>'Role', :_parent=>self).merge(val)
      inner_spec.sql.joins << "join roles_users ru on ru.role_id = #{inner_spec.table_alias}.extension_id"
      merge({
        :extension_id => ValueSpec.new(['in',inner_spec],self),
        :extension_type => 'User'
      })
    end

    def member(val)
      inner_spec = CardSpec.build(:return=>'ru.role_id', :extension_type=>'User', :_parent=>self).merge(val)
      inner_spec.sql.joins << "join roles_users ru on ru.user_id = #{inner_spec.table_alias}.extension_id"
      merge({
        :extension_id => ValueSpec.new(['in',inner_spec],self),
        :extension_type => 'Role'
      })
    end

    
    def count(val)
      raise(Wagn::WqlError, "count works only on outermost spec") if @parent
      join_spec = { :id=>SqlCond.new("#{table_alias}.id") } 
      val.each do |relation, subspec|
        subquery = CardSpec.build(:_parent=>self, :return=>:count, relation.to_sym=>join_spec).merge(subspec).to_sql
        sql.fields << "#{subquery} as #{relation}_count"
      end
    end

    def refspec(key, cardspec)
      if cardspec == '_none'
        key = :link_to_missing
        cardspec = 'blank'
      end
      cardspec = CardSpec.build(:return=>'id', :_parent=>self).merge(cardspec)
      merge field(:id) => ValueSpec.new(['in',RefSpec.new([key,cardspec])], self)
    end
    
    def subspec(spec, additions={ :return=>'id' }, negate=false)   
      additions = additions.merge(:_parent=>self)
      join = negate ? 'not in' : 'in'
      #warn "#{self}.subspec(#{additions}, #{spec})"
      ValueSpec.new([join,CardSpec.build(additions).merge(spec)], self)
    end 
    
    def to_sql(*args)
      # Basic conditions
      sql.conditions << @spec.collect do |key, val|   
        key = key.to_s
        key = key.gsub(/\:\d+/,'')  
        val.to_sql(key)
      end.join(" #{@mods[:join]} ")                 

      # Default fields/return handling   
      return "(" + sql.conditions.last + ")" if @mods[:return]==:condition     
      sql.fields.unshift case @mods[:return]
        when :condition; 
        when :list; "#{table_alias}.*"
        when :count; "count(*)"
        when :first; "#{table_alias}.*"
        when :ids;   "id"
        when :name_content;
          sql.joins << "join revisions r on r.card_id = #{table_alias}.id"
          "#{table_alias}.name, r.content"
        when :codename; 
          sql.joins << "join cardtypes as extension on extension.id=#{table_alias}.extension_id "
          'extension.class_name'
        else @mods[:return]
      end
      
      # Permissions       
      t = table_alias
      #unless User.current_user.login.to_s=='wagbot' #
      unless System.always_ok? or (Wql.root_perms_only && !root?)
        user_roles = [Role[:anon].id]
        unless User.current_user.login.to_s=='anon'
          user_roles += [Role[:auth].id] + User.current_user.roles.map(&:id)
        end                                                                
        user_roles = user_roles.map(&:to_s).join(',')
        # type!=User is about 6x faster than type='Role'...
        sql.conditions << %{ (#{t}.reader_type!='User' and #{t}.reader_id IN (#{user_roles})) }
      end

=begin      
      if !@mods[:group_tagging].blank?
        card_class = @mods[:group_tagging] 
        fields = Card::Base.columns.map {|c| "#{table_alias}.#{c.name}"}.join(", ")
                              
        raise("too many existing fields") if sql.fields.length > 1
        sql.fields[0] = fields
        
        join = " join cards c2 on c2.tag_id=#{table_alias}.id  " 
        join += " join cards c3 on c2.trunk_id=c3.id and c3.type=#{quote(card_class)}"  unless card_class==:any
        sql.joins << join
        
        sql.group = "GROUP BY #{fields}"
        @mods[:sort] = 'count'
        @mods[:dir] = 'desc'
      end
=end
            
      # Order 
      unless @parent or @mods[:return]==:count
        order_key ||= @mods[:sort].blank? ? "update" : @mods[:sort]
        dir = @mods[:dir].blank? ? (DEFAULT_ORDER_DIRS[order_key]||'desc') : @mods[:dir]
        sql.order = "ORDER BY "
        sql.order << case order_key
          when "update"; "#{table_alias}.updated_at #{dir}"
          when "create"; "#{table_alias}.created_at #{dir}"
          when /^(name|alpha)$/;  "#{table_alias}.key #{dir}"  
          when "count";  "count(*) #{dir}, #{table_alias}.name asc"
          when 'content'
            sql.joins << "join revisions r2 on r2.id=#{self.table_alias}.current_revision_id"
            "lower(r2.content) #{dir}"
          when "relevance";  
            if !sql.relevance_fields.empty?
              sql.fields << sql.relevance_fields
              "name_rank desc, content_rank desc" 
            else 
              "#{table_alias}.updated_at desc"
            end     
          else 
            sql.fields << sql.count_fields if sql.count_fields
            "#{order_key} #{dir}" 
        end 
      end
                             
      # Misc
      sql.tables = "cards #{table_alias}"
      sql.conditions << "#{table_alias}.trash='f'"
      sql.limit = @mods[:limit].blank? ? "" : "LIMIT #{@mods[:limit].to_i}"
      sql.offset = @mods[:offset].blank? ? "" : "OFFSET #{@mods[:offset].to_i}"
      
      sql.to_s
    end
    
  end
    
  class RefSpec < Spec
    def initialize(spec)
      @spec = spec   
      @refspecs = {
        :refer_to => ['card_id','referenced_card_id',''],
        :link_to => ['card_id','referenced_card_id',"link_type='#{WikiReference::LINK}' AND"],
        :link_to_missing => ['card_id', 'referenced_card_id', "link_type='#{WikiReference::WANTED_LINK}'"],
        :include => ['card_id','referenced_card_id',"link_type='#{WikiReference::TRANSCLUSION}' AND"],
        :referred_to_by=> ['referenced_card_id', 'card_id', ''],
        :linked_to_by => ['referenced_card_id','card_id',"link_type='#{WikiReference::LINK}' AND"],
        :included_by  => ['referenced_card_id','card_id',"link_type='#{WikiReference::TRANSCLUSION}' AND"]
      }
    end
    
    def to_sql(*args)
      f1, f2, where = @refspecs[@spec[0]]
      and_where = (@spec[0] == :link_to_missing) ? '' : "#{f2} IN #{@spec[1].to_sql}"
      %{(select #{f1} from wiki_references where #{where} #{and_where})}
    end
  end
  
  class ValueSpec < Spec
    def initialize(spec, cardspec)
      @cardspec = cardspec
      
      # bare value shortcut
      @spec = case spec   
        when ValueSpec; spec.instance_variable_get('@spec')  # FIXME whatta fucking hack (what's this for?)
        when Array;     spec
        when String;    ['=', spec]
        when Integer;   ['=', spec]
  #      when nil;       ['is', 'null']
        else raise("Invalid Condition Spec #{spec.inspect}")
      end
      @spec[0] = @spec[0].to_s
       
      # operator aliases
      if target = OPERATORS[@spec[0]]
        @spec[0] = target
      end

      # check valid operator
      raise("Invalid Operator #{@spec[0]}") unless OPERATORS.has_key?(@spec[0])

      # handle IN
      if @spec[0]=='in' and !@spec[1].is_a?(CardSpec) and !@spec[1].is_a?(RefSpec)
        @spec = [@spec[0], @spec[1..-1]]
      end
    end
    
    def op
      @spec[0]
    end
    
    def sqlize(v)
      case v
        when CardSpec, RefSpec, SqlCond; v.to_sql
        when Array;    "(" + v.flatten.collect {|x| sqlize(x)}.join(',') + ")"
        else quote(v.to_s)
      end
    end
    
    def to_sql(field)
      clause = nil
      op,v = @spec
      v=@cardspec.card if v=='_self'
      
      case field
      when "content"
        @cardspec.sql.joins << "join revisions r on r.id=#{@cardspec.table_alias}.current_revision_id"
        field = 'r.content'
      when "type"
        v = [v].flatten.map do |val| 
          Cardtype.classname_for(  val.is_a?(Card::Base) ? val.name : val  )
        end
        v = v[0] if v.length==1
      when "cond"
        clause = "(#{sqlize(v)})"
      else   
        field = "#{@cardspec.table_alias}.#{field}"
      end
      
      
      clause ||=
        if op=='~'
          cxn, v = match_prep(v,@cardspec)
          %{#{field} #{cxn.match(sqlize(v))}}
        else
          "#{field} #{op} #{sqlize(v)}"
        end
      
    end
  end         
end