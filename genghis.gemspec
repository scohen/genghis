require 'rubygems'
require 'rake'

spec = Gem::Specification.new do |s|
  s.name = "genghis"
  s.version = "1.4.0"
  s.author = "Steve Cohen"
  s.summary = "Genghis is a mongoDB configuration and resilience framework"
  s.email = "scohen@scohen.org"
  s.homepage = "http://github.com/scohen/genghis"
  s.platform = Gem::Platform::RUBY
  s.files = Dir['lib/**/*.rb']
  s.require_path = "lib"
  s.autorequire = "genghis"
  s.has_rdoc = true
  s.extra_rdoc_files = ["README.rdoc"]
  s.add_dependency("mongo", ">=1.2.0")
end
