puts
say "Just checking you're up to date..."

# for some reason `require 'json'` in the main scope results
# in a `gem 'json'` line in the Gemfile hence this wrapper module
module LatestVersion
  require 'net/http'
  require 'json'

  def self.get
    json = Net::HTTP.get URI('https://rubygems.org/api/v1/gems/rails.json')
    JSON.parse(json)['version']
  end
end

latest = LatestVersion.get

if Rails::VERSION::STRING != latest
  require 'shellwords'

  puts
  say "Hey it looks like rails #{latest} is out, but you're using #{Rails::VERSION::STRING}", :yellow
  puts
  say "You should upgrade to rails #{latest}:", :yellow
  say "gem install rails -v#{latest}", :yellow
  puts
  say "Then remove this folder:", :yellow
  say "rm -rf #{app_name}", :yellow
  puts
  say "And finally regenerate your app:", :yellow
  say "rails #{ARGV.map(&:shellescape).join(' ')}", :yellow
  puts
  say "But I won't force you, I'm a gentleman...", :yellow
  puts
  exit unless yes? "Should I continue with rails #{Rails::VERSION::STRING} anyway?", :blue
else
  say "Yep, your good to go!", :green
end

puts

create_file '.ruby-version', "#{RUBY_VERSION}\n"

gem 'simple_form'
gem 'high_voltage'

gem_group :development do
  gem 'better_errors'
  gem 'binding_of_caller'
  gem 'rack-mini-profiler'
  gem 'letter_opener'
  gem 'capistrano', '~> 2'
  gem 'pry-rails'
end

gem_group :test, :development do
  gem 'rspec-rails'
  gem 'factory_girl_rails'
  gem 'simplecov', require: false
  gem 'bundler-audit'
end

gem_group :test do
  gem 'shoulda-matchers'
  gem 'database_cleaner'
  gem 'timecop'
end

gem 'puma'
gem 'puma_worker_killer'
gem 'bugsnag'
gem 'rack-attack'
gem 'capistrano-slack-notify'

gsub_file 'Gemfile', /(#(.+)\n)?gem ('|")turbolinks('|")\n/, ''
gsub_file 'app/assets/javascripts/application.js', /\/\/= require turbolinks\n/, ''

run 'bundle install'

environment 'config.middleware.use Rack::Attack'
environment 'config.action_mailer.delivery_method = :letter_opener', env: 'development'
environment 'config.assets.quiet = true', env: 'development'

initializer 'rack_attack.rb', <<-RUBY
class Rack::Attack
  Rack::Attack.blacklist('block alihack requests') do |req|
    req.path == '/ali.txt'
  end
end
RUBY

generate 'simple_form:install'
generate 'rspec:install'

prepend_to_file 'spec/spec_helper.rb', <<-RUBY
require 'simplecov'
SimpleCov.start 'rails'\n
RUBY

append_to_file 'Rakefile', <<-RUBY
\nif Rails.env.test?
  require 'rspec/core/rake_task'
  task :default => :spec
end
RUBY

file 'spec/support/database_cleaner.rb', <<-RUBY
RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner.clean_with(:deletion)
  end

  config.before(:each) do
    DatabaseCleaner.strategy = :transaction
  end

  config.before(:each, :js => true) do
    DatabaseCleaner.strategy = :deletion
  end

  config.before(:each) do
    DatabaseCleaner.start
  end

  config.after(:each) do
    DatabaseCleaner.clean
  end
end
RUBY

file 'app/views/pages/home.html.erb', "<h1>Home</h1>\n"
route "root to: 'high_voltage/pages#show', id: 'home'"

run 'cp config/environments/production.rb config/environments/staging.rb'

file '.travis.yml', <<-RUBY
language: ruby
rvm:
  - #{RUBY_VERSION}
before_script:
  - createdb #{app_name}_test
  - cp config/database.yml{.travis,}
  - cp config/secrets.yml{.travis,}
  - 'bundle exec bundle-audit update && bundle exec bundle-audit check'
cache: bundler
addons:
  code_climate:
    repo_token: <add here>
notifications:
  slack:
    on_failure: always
    on_success: change
    rooms:
      - rawnet: <add here>
after_success:
  - "[[ $TRAVIS_BRANCH = 'master' ]] && bundle exec cap staging deploy"
RUBY

file 'Capfile', <<-RUBY
load 'deploy'
load 'config/deploy'
RUBY

file 'config/deploy.rb', <<-RUBY
load 'deploy/assets'
require 'bundler/capistrano'
require 'capistrano-slack-notify'

set :default_environment, {
  'PATH' => '$HOME/.rbenv/shims:$HOME/.rbenv/bin:$PATH'
}

set :repository, 'git@github.com:rawnet/#{app_name}'
set :deploy_via, :remote_cache
set :scm, :git
default_run_options[:pty] = true

set :stages, %w(staging production)
set :default_stage, 'staging'
require 'capistrano/ext/multistage'

set :use_sudo, false
set :application, '#{app_name}'
set :keep_releases, 5
set :user, 'rails'
set(:deploy_to) { File.join('', 'home', user, 'apps', application, stage.to_s) }
ssh_options[:forward_agent] = true

set :slack_webhook_url, '<slack webhook url starting https://hooks.slack.com>'
set :slack_room, '<slack channel>'

namespace :deploy do
  task :restart do
    run "kill -USR2 `cat \#{current_path}/tmp/pids/puma.pid`"
    run "for pidfile in \#{current_path}/tmp/pids/resque.*.pid; do kill -QUIT `cat $pidfile`; rm $pidfile; done"
  end
end

def symlink(source, destination)
  run "rm \#{destination} > /dev/null 2>&1; ln -sf \#{source} \#{destination}"
end

namespace :symlinks do
  task :database do
    symlink "\#{shared_path}/config/database.yml", "\#{release_path}/config/database.yml"
  end

  task :secrets do
    symlink "\#{shared_path}/config/secrets.yml", "\#{release_path}/config/secrets.yml"
  end
end

before "deploy:assets:precompile", "symlinks:database", "symlinks:secrets"
after "deploy:update", "deploy:migrate", "deploy:cleanup"

before 'deploy', 'slack:starting'
after  'deploy', 'slack:finished'
before 'deploy:rollback', 'slack:failed'

require './config/boot'
RUBY

file 'config/deploy/production.rb', <<-RUBY
set :rails_env, 'production'
set :branch,    'master'
server '<production ip address>', :app, :web, :db, primary: true
RUBY

file 'config/deploy/staging.rb', <<-RUBY
set :rails_env, 'staging'
set :branch,    'staging'
server '<staging ip address>', :app, :web, :db, primary: true
RUBY

append_to_file '.gitignore', ".DS_Store\n"
append_to_file '.gitignore', "config/database.yml\n"
append_to_file '.gitignore', "config/secrets.yml\n"
append_to_file '.gitignore', "coverage\n"

run 'cp config/database.yml{,.example}'
run 'cp config/secrets.yml{,.example}'

file 'config/database.yml.travis', <<-RUBY
test:
  adapter: postgresql
  database: #{app_name}_test
  encoding: unicode
  username: travis
RUBY

file 'config/secrets.yml.travis', <<-RUBY
test:
  secret_key_base: 4cb80c379051ae8943eb8d2917f327a7bbdd708b37a211597e737aaf43f56970fbf221a6f98525c5bb06408f349d35b3afb3b40de6e69ffeb2371852fcf5d8b4
RUBY

remove_file 'README.rdoc'
# README from https://github.com/rawnet/handbook/blob/master/Back-End/Readme%20Template.md
file 'README.md', <<-MD
# #{app_name}

<Add Travis Build Badge (click badge in travis to get markdown link)>
<Add Code Climate Badge (under settings -> badges)>
<Add Test Coverage Badge  (under settings -> badges)>

Staging: http://staging.url

Production: http://production.url

List any other environment URL here.

## Getting Started & Running Locally

Detail how to get the project running locally, including any commands,
requirements or 3rd party tools that need to be installed. For Rails projects, this
may state if the project uses `rails s`, `script/server` or `foreman start`.

## How To Deploy

Mention the steps to deploy to both Staging and Production environments.

Does the project use a CI Server to deploy to Staging?

Do we rely on any automation/GitHub callbacks?

## Known Problems

Does the server fail to restart after deployment?

Do you need to restart the application for `routes.rb` to apply?

Highlight any known problems here to help the team get running with the project.
MD

git :init
git add: '-A'
git commit: '-m "Initial commit"'

say "\nYou're nearly ready to go... yeah, pretty Rock and Roll right!?", :blue

say %Q{
Now you just gotta:
1) Create a new GitHub repo (https://github.com/new) then:

   git remote add origin git@github.com:rawnet/#{app_name}
   git push -u origin master

2) Create a new project in Bugsnag (https://bugsnag.com), grab the API key and run:

   rails generate bugsnag <project api key>

3) Add this project to Travis CI and add missing details to .travis.yml

4) Add the project to Code Climate (https://codeclimate.com)

5) Set up a staging environment on Rawnet's Digital Ocean account

6) Add missing info in deploy file
}

