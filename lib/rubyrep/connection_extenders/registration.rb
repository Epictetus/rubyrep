module RR
  module ConnectionExtenders
    # Returns a Hash of currently registered connection extenders
    # (Empty Hash if no connection extenders were defined)
    def self.extenders
      @extenders ||= {}
      @extenders
    end
  
    # Registers one or multiple connection extender
    # extender is a Hash with 
    #   key::  The adapter symbol as used by ActiveRecord::Connection Adapters, e. g. :postgresql
    #   value: Name of the module implementing the connection extender
    def self.register(extender)
      @extenders ||= {}
      @extenders.merge! extender
    end
  end
end