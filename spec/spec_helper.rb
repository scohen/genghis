require File.expand_path(File.dirname(__FILE__) +  '/../lib/genghis.rb')

def set_yaml_file(file_as_hash)
  YAML.stub!(:load_file).and_return(file_as_hash)  
end