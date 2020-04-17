# frozen_string_literal: true

require 'sinatra'
require 'sinatra/config_file'
require 'sinatra/content_for'
require 'uri'
require 'octokit'
require 'httparty'
require 'json'
require 'base64'
require 'open-uri'
require 'safe_yaml'
require 'liquid'
require 'sinatra/reloader' if development?
require './env' if File.exist?('env.rb')

SafeYAML::OPTIONS[:default_mode] = :safe

configure { set :server, :puma }

config_yml = "#{::File.dirname(__FILE__)}/config.yml"
config_yml = "#{::File.dirname(__FILE__)}/test/fixtures/config.yml" if test?

config_file config_yml

# Put helper functions in a module for easy testing.
# https://www.w3.org/TR/micropub/#error-response
module AppHelpers
  def error(error)
    description = nil
    case error
    when 'invalid_request'
      code = 400
      description = 'Invalid request'
    when 'insufficient_scope'
      code = 401
      description = 'Insufficient scope information provided.'
    when 'invalid_repo'
      code = 422
      description = "repository doesn't exit."
    when 'unauthorized'
      code = 401
    end
    halt code, JSON.generate(error: error, error_description: description)
  end

  def verify_token
    resp = HTTParty.get(Sinatra::Application.settings.micropub[:token_endpoint], {
                          headers: {
                            'Content-type' => 'application/x-www-form-urlencoded',
                            'Authorization' => "Bearer #{@access_token}"
                          }
                        })
    decoded_resp = URI.decode_www_form(resp).each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
    error('insufficient_scope') unless (decoded_resp.include? :scope) && (decoded_resp.include? :me)

    decoded_resp
  end

  def publish_post(params)
    # Authenticate
    client = Octokit::Client.new(access_token: ENV['GITHUB_ACCESS_TOKEN'])

    date = DateTime.parse(params[:published])
    filename = date.strftime('%F')
    params[:slug] = create_slug(params)
    filename << "-#{params[:slug]}.md"

    logger.info "Filename: #{filename}"
    @location = settings.sites[params[:site]]['site_url'].dup
    @location << create_permalink(params)

    # Verify the repo exists
    repo = "#{settings.github_username}/#{settings.sites[params[:site]]['github_repo']}"
    error('invalid_repo') unless client.repository?(repo)

    files = {}

    # Download any photos we want to include in the commit
    # TODO: Per-repo settings take pref over global. Global only at the mo
    if settings.download_photos && !params[:photo].nil?
      params[:photo] = download_photos(params)
      params[:photo].each do |photo|
        files.merge!(photo.delete('content')) if photo['content']
      end
    end

    template = File.read("templates/#{params[:type]}.liquid")
    content = Liquid::Template.parse(template).render(stringify_keys(params))

    ref = 'heads/master' # TODO: Use API to determine pages branch or use override
    sha_latest_commit = client.ref(repo, ref).object.sha
    sha_base_tree = client.commit(repo, sha_latest_commit).commit.tree.sha

    files["_posts/#{filename}"] = Base64.encode64(content)

    new_tree = files.map do |path, new_content|
      Hash(
        path: path,
        mode: '100644',
        type: 'blob',
        sha: client.create_blob(repo, new_content, 'base64')
      )
    end

    sha_new_tree = client.create_tree(repo, new_tree, base_tree: sha_base_tree).sha
    commit_message = "New #{params[:type]}"
    sha_new_commit = client.create_commit(repo, commit_message, sha_new_tree, sha_latest_commit).sha
    client.update_ref(repo, ref, sha_new_commit)

    status 201
    headers 'Location' => @location.to_s
    body content if ENV['RACK_ENV'] == 'test'
  end

  # Download the photo and add to GitHub repo if config allows
  #
  # WARNING: the handling of alt in JSON may change in the future.
  # See https://www.w3.org/TR/micropub/#uploading-a-photo-with-alt-text
  def download_photos(params)
    params[:photo].each_with_index do |photo, i|
      alt = photo.is_a?(String) ? '' : photo[:alt]
      url = photo.is_a?(String) ? photo : photo[:value]
      begin
        filename = url.split('/').last
        upload_path = "#{settings.sites[params[:site]]['image_dir']}/#{filename}"
        photo_path = ''.dup
        photo_path << settings.sites[params[:site]]['site_url'] if settings.sites[params[:site]]['full_image_urls']
        photo_path << "/#{upload_path}"
        tmpfile = Tempfile.new(filename)
        File.open(tmpfile, 'wb') do |f|
          resp = HTTParty.get(url, stream_body: true, follow_redirects: true)
          raise unless resp.success?

          f.write resp.body
        end
        content = { upload_path => Base64.encode64(tmpfile.read) }
        params[:photo][i] = { 'url' => photo_path, 'alt' => alt, 'content' => content }
      rescue StandardError
        # Fall back to orig url if we can't download
        params[:photo][i] = { 'url' => url, 'alt' => alt }
      end
    end
    params[:photo]
  end

  # Grab the contents of the file referenced by the URL received from the client
  # This assumes the final part of the URL contains part of the filename as it
  # appears in the repository.
  def get_post(url)
    fuzzy_filename = url.split('/').last
    client = Octokit::Client.new(access_token: ENV['GITHUB_ACCESS_TOKEN'])
    repo = "#{settings.github_username}/#{settings.sites[params[:site]]['github_repo']}"
    code = client.search_code("filename:#{fuzzy_filename} repo:#{repo}")
    # This is an ugly hack because webmock doesn't play nice - https://github.com/bblimke/webmock/issues/449
    code = JSON.parse(code, symbolize_names: true) if ENV['RACK_ENV'] == 'test'
    content = client.contents(repo, path: code[:items][0][:path]) if code[:total_count] == 1
    decoded_content = Base64.decode64(content[:content]).force_encoding('UTF-8').encode unless content.nil?

    jekyll_post_to_json decoded_content
  end

  def jekyll_post_to_json(content)
    # Taken from Jekyll's Jekyll::Document YAML_FRONT_MATTER_REGEXP
    if content =~ /\A(---\s*\n.*?\n?)^((---|\.\.\.)\s*$\n?)/m
      content = $' # $POSTMATCH doesn't work for some reason
      front_matter = SafeYAML.load(Regexp.last_match(1))
    end

    data = {}
    data[:type] = ['h-entry'] # TODO: Handle other types.
    data[:properties] = {}
    data[:properties][:published] = [front_matter['date']]
    data[:properties][:content] = content.nil? ? [''] : [content.strip]
    data[:properties][:slug] = [front_matter['permalink']] unless front_matter['permalink'].nil?
    data[:properties][:category] = front_matter['tags'] unless front_matter['tags'].nil? || front_matter['tags'].empty?

    JSON.generate(data)
  end

  def create_slug(params)
    # Use the provided slug
    slug =
      if params.include?(:slug) && !params[:slug].nil?
        params[:slug]
      # If there's a name, use that
      elsif params.include?(:name) && !params[:name].nil?
        slugify params[:name]
      else
        # Else generate a slug based on the published date.
        DateTime.parse(params[:published]).strftime('%s').to_i % (24 * 60 * 60)
      end
    slug.to_s
  end

  def create_permalink(params)
    permalink_style = params[:permalink_style] || settings.sites[params[:site]]['permalink_style']
    date = DateTime.parse(params[:published])

    # Common Jekyll permalink template variables - https://jekyllrb.com/docs/permalinks/#template-variables
    template_variables = {
      ':year' => date.strftime('%Y'),
      ':month' => date.strftime('%m'),
      ':i_month' => date.strftime('%-m'),
      ':day' => date.strftime('%d'),
      ':i_day' => date.strftime('%-d'),
      ':short_year' => date.strftime('%y'),
      ':hour' => date.strftime('%H'),
      ':minute' => date.strftime('%M'),
      ':second' => date.strftime('%S'),
      ':title' => params[:slug],
      ':categories' => ''
    }

    permalink_style.gsub(/(:[a-z_]+)/, template_variables).gsub(%r{(//)}, '/')
  end

  def slugify(text)
    text.downcase.gsub('/[\s.\/_]/', ' ').gsub(/[^\w\s-]/, '').squeeze(' ').tr(' ', '-').chomp('-')
  end

  def stringify_keys(hash)
    hash.is_a?(Hash) ? hash.collect { |k, v| [k.to_s, stringify_keys(v)] }.to_h : hash
  end

  # Syndicate to destinations supported by silo.pub as that's what we use
  # instead of having to implement all the APIs ourselves.
  #
  # If no destination is provided, assume it's a query and return all destinations.
  def syndicate_to(params = nil)
    # TODO: Per-repo settings take pref over global. Global only at the mo
    # TODO Add the response URL to the post meta data
    # Note: need to use Sinatra::Application.syndicate_to here until we move to
    # modular approach so the settings can be accessed when testing.
    destinations = Sinatra::Application.settings.syndicate_to.values
    clean_dests = []
    destinations.each do |e|
      clean_dests << e.reject { |k| k == 'silo_pub_token' }
    end
    return JSON.generate("syndicate-to": clean_dests) if params.nil?

    dest_entry = destinations.find do |d|
      dest = params[:"syndicate-to"][0] if params.key?(:"syndicate-to")
      d['uid'] == dest
    end || return

    silo_pub_token = dest_entry['silo_pub_token']
    uri = URI.parse('https://silo.pub/micropub')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.port == 443)
    request = Net::HTTP::Post.new(uri.request_uri)
    request.initialize_http_header('Authorization' => "Bearer #{silo_pub_token}")

    form_data = {}
    form_data['name'] = params[:name] if params[:name]
    form_data['url'] = @location
    form_data['content'] = params[:content]

    request.set_form_data(form_data)
    resp = http.request(request)
    JSON.parse(resp.body)['id_str'] if ENV['RACK_ENV'] == 'test'
  end

  # Process and clean up params for use later
  def process_params(post_params)
    # Bump off the standard Sinatra params we don't use
    post_params.reject! { |key, _v| key =~ /^splat|captures|site/i }

    error('invalid_request') if post_params.empty?

    # JSON-specific processing
    if env['CONTENT_TYPE'] == 'application/json'
      if post_params[:type][0]
        post_params[:h] = post_params[:type][0].tr('h-', '')
        post_params.delete(:type)
      end
      post_params.merge!(post_params.delete(:properties))
      if post_params[:content]
        post_params[:content] =
          if post_params[:content][0].is_a?(Hash)
            post_params[:content][0][:html]
          else
            post_params[:content][0]
          end
      end
      post_params[:name] = post_params[:name][0] if post_params[:name]
    else
      # Convert all keys to symbols from form submission
      post_params = post_params.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      post_params[:photo] = [*post_params[:photo]] if post_params[:photo]
      post_params[:"syndicate-to"] = [*post_params[:"syndicate-to"]] if post_params[:"syndicate-to"]
    end

    # Secret functionality: We may receive markdown in the content.
    # If the first line is a header, set the name with it
    first_line = post_params[:content].match(/^#+\s?(.+$)\n+/) if post_params[:content]
    if !first_line.nil? && !post_params[:name]
      post_params[:name] = first_line[1].to_s.strip
      post_params[:content].sub!(first_line[0], '')
    end

    # Add in a few more params if they're not set
    # Spec says we should use h-entry if no type provided.
    post_params[:h] = 'entry' unless post_params.include? :h
    # It's nice to honour the client's published date, if set, else set one.
    post_params[:published] = Time.now.to_s unless post_params.include? :published

    post_params
  end

  def post_type(post_params)
    case post_params[:h]
    when 'entry'
      mapping = { name: :article, in_reply_to: :reply, repost_of: :repost, bookmark_of: :bookmark, content: :note }
      mapping.each { |key, type| return type if post_params.include?(key) }
      # Dump all params into this template as it doesn't fit any other type.
      :dump_all
    else
      post_params[:h].to_sym
    end
  end
end

Sinatra::Application.helpers AppHelpers

# My own message for 404 errors
not_found do
  '404: Not Found'
end

before do
  # Pull out and verify the authorization header or access_token
  if env['HTTP_AUTHORIZATION']
    @access_token = env['HTTP_AUTHORIZATION'].match(/Bearer (.*)$/)[1]
  elsif params['access_token']
    @access_token = params['access_token']
  else
    logger.info 'Received request without a token'
    error('unauthorized')
  end

  # Remove the access_token to prevent any accidental exposure later
  params.delete('access_token')

  # Verify the token
  verify_token unless ENV['RACK_ENV'] == 'development'
end

# Query
get '/micropub/:site' do |site|
  halt 404 unless settings.sites.include? site
  halt 404 unless params.include? 'q'

  case params['q']
  when /config/
    status 200
    headers 'Content-type' => 'application/json'
    # TODO: Populate this with media-endpoint and syndicate-to when supported.
    #       Until then, empty object is fine.
    body JSON.generate({})
  when /source/
    status 200
    headers 'Content-type' => 'application/json'
    # body JSON.generate("response": get_post(params[:url]))
    # TODO: Determine what goes in here
    body get_post(params[:url])
  when /syndicate-to/
    status 200
    headers 'Content-type' => 'application/json'
    body syndicate_to
  end
end

post '/micropub/:site' do |site|
  halt 404 unless settings.sites.include? site

  # Normalise params
  post_params =
    if env['CONTENT_TYPE'] == 'application/json'
      JSON.parse(request.body.read.to_s, symbolize_names: true)
    else
      params
    end
  post_params = process_params(post_params)
  post_params[:site] = site

  # Check for reserved params which tell us what to do:
  # h = create entry
  # q = query the endpoint
  # action = update, delete, undelete etc.
  error('invalid_request') unless post_params.any? { |k, _v| %i[h q action].include? k }

  # Determine the template to use based on various params received.
  post_params[:type] = post_type(post_params)

  logger.info post_params unless ENV['RACK_ENV'] == 'test'
  # Publish the post
  publish_post post_params

  # Syndicate the post
  syndicate_to post_params
end
