# -*- encoding : utf-8 -*-

class User < ActiveRecord::Base
end

class UserDataToCards < ActiveRecord::Migration
  include Wagn::MigrationHelper  
  
  def up
    contentedly do
      
      puts "adding new codename cards"
      [ :password, :token, :salt, :status, :signin ].each do |codename|
        Card.create! :name=>"*#{codename}", :codename=>codename
      end
      
      Card::Codename.reset_cache
      
      puts "setting create permissions for account cards (inherit from left)"
      [ :password, :token, :salt, :status, :email, :account ].each do |codename|
        rule_name = [ codename, :right, :create ].map { |code| Card[code].name } * '+'
        rule_card = Card.fetch rule_name, :new=>{}
        rule_card.content = '_left'
        rule_card.save!
      end
      
      puts "making email and password fields default to Phrase cards"
      [:email, :password].each do |field|
        rulename = [field, :right, :default].map { |code| Card[code].name } * '+'
        Card.create! :name=>rulename, :type_id=>Card::PhraseID
      end
      
      puts "signin permissions"
      [:read, :update].each do |setting|
        rulename = [ :signin, :self, setting ].map { |code| Card[code].name } * '+'
        Card.create! :name=>rulename, :content=>"[[#{Card[:anyone].name}]]"
      end
      
      puts "turn captcha off by default on signup"
      rulename = [:signup, :type, :captcha].map { |code| Card[code].name } * '+'
      captcha_rule = Card.fetch rulename, :new=>{}
      captcha_rule.content = '0'
      captcha_rule.save!
      
      puts "supporting legacy handling of +*email on User cards"
      oldname = [       :email,           :right, :structure].map { |code| Card[code].name } * '+'
      newname = [:user, :email, :type_plus_right, :structure].map { |code| Card[code].name } * '+'
      Card[oldname].update_attributes! :name=>newname
      
      
      puts "importing all user details (for those not in trash) into +*account attributes"
      Card::Env[:no_password_encryptions] = true
      User.all.each do |user|
        base = Card[user.card_id]
        if base and !base.trash
          puts "~ importing details for #{base.name}"
          date_args = { :created_at => user.created_at, :updated_at => user.updated_at }
          [ :email, :salt, :password, :status ].each do |field|
            cardname = "#{base.name}+#{Card[:account].name}+#{Card[field].name}"
            user_field = ( field==:password ? :crypted_password : field )
            if content = user.send( user_field )
              Card.create! date_args.merge( :name=>cardname, :content=>content)
            end
          end
        end
      end
      
    end
  end

end