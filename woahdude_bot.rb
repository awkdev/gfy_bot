class WoahdudeBot
	# List of required Gems
	require 'snoo'
	require 'json'
	require 'nokogiri'
	require 'net/http'
	require 'open-uri'
	require 'cgi'
	require 'time'
	require 'filesize'
	require 'hawk'
	require 'httparty'
	require 'action_view'

	include ActionView::Helpers::NumberHelper

	# ====================================
	# NOTHING WILL BE UPLOADED TO GFYCAT OR
	# POSTED TO REDDIT IF DEBUG IS SET TO TRUE.
	# =====================================
	DEBUG = false

	# Initialize the bot with a hash containing basic params as given below:
	# :args => {
	#	:username => 'gfy_bot',
	#	:password => 'xxxxxxxx',
	#	:time_interval => 5, # in minutes
	#	:subreddits => ['india', 'askreddit'] # array of subs to crawl
	# }
	def initialize(args = {})
		@username = args[:username] || raise(ArgumentError.new("Please provide a username for bot's Reddit account while initializing"))
		@password = args[:password] || raise(ArgumentError.new("Please provide a password for bot's Reddit account while initializing"))
		@hawk_id = args[:hawk_id] || 'xyz'
		@hawk_key = args[:hawk_key] || 'xyz'
		@time_interval = args[:time_interval] || 2
		@subreddits = args[:subreddits] || ['thisismyspace']
		@limit = 20 # no. of posts/comments to fetch in one go
		@blockedUsers = ['imgurHostBot']
		@nsfw_subs = args[:nsfw_subs]

		# GFY Upload URL using the API. Returns a JSON
		# http://upload.gfycat.com/transcode?fetchUrl=http%3A%2F%2Fi.imgur.com%2FCXE9FRs.gif
		@gfydom = 'upload.gfycat.com'
		@gfyurl = '/transcode?fetchUrl='

		# The logger file contains runtime details from the last crawl. This function reads the file and saves imp details in params hash
		@file = 'logfile-woahdude.txt'
		@params = {}
		@current_time = nil
		initializeParams

		# links is an array of hashes containing the links in posts/comments and their IDs so the bot can reply to them later
		# @links = [
		#		{
		#				:links => ['http://imgur.com/test.gif'],
		#				:id => 't1_c3c3c3c3',
		#				:subreddit => 'India'
		#		},
		#		{
		#				:links => ['http://imgur.com/test2.gif'],
		#				:id => 't2_c3c3c3c3',
		# 				:subreddit => 'AskReddit'
		#		}
		# ]
		@links = []

		# If we have modhash and cookie, use it to login or create new session
		if @params['modhash'].nil? && @params['cookies'].nil?
			bot_options = {
					:username => @username,
					:password => @password,
			}
			puts 'No cookie found. Logging in'
		else
			bot_options = {
					:modhash => @params['modhash'],
					:cookies => @params['cookies']
			}
			puts 'Logging in via cookie'

		end
		# Name of the bot using Snoo Reddit API wrapper
		@gfybot = Snoo::Client.new(bot_options)
		if @gfybot.cookies.nil?
			if bot_options[:cookies].nil?
				puts 'Unable to login. Pls fix'
				exit!
			else
				@gfybot = Snoo::Client.new({
																			 :username => @username,
																			 :password => @password,
																	 })

				@params['modhash'] = @gfybot.modhash
				@params['cookies'] = @gfybot.cookies
				puts 'cookie didnt work. logged in again'
			end
		else
			@params['modhash'] = @gfybot.modhash
			@params['cookies'] = @gfybot.cookies
		end
	end

	# Reads the logfile saved on disc which contains few runtime details gathered from the last run of the bot. If the file does not exist, create it.
	def initializeParams
		# Check if the file exists. If yes: read the params, if not: create it and log an OLD timestamp to it so we start crawling now.
		File.exist?(@file) ? readLogFile : logTime({:old => true})
	end

	# The logfile contains 3 lines, both a key/value pair separated by a tilde ( ~ ) sign. So we extract it into a ruby hash for our use
	# ----------------- raw logfile --------------
	# time~2014-01-01 12:16:09 +0530
	# last_comment~t1_c3c3c3c3
	# last_post~t3_cc2c2c2
	# ----- after extraction it becomes ----------
	# params = {
	#	:time => '2014-01-01 12:16:09 +0530',
	#	:last_comment => 't1_c3c3c3c3'
	#	:last_post => 't3_cc2c2c2'
	# }
	# --------------------------------------------
	def readLogFile
		File.readlines(@file).each do |line|
			key = line.split('~').first
			value = line.split('~').last
			value.gsub!(/(.*)\n?$/,'\1') # some platform append a \n in the end. Just getting rid of it.
			@params[key] = value
		end
	end

	# Check the time difference between when the bot was last run, and now and return it (minutes).
	def check_time_interval
		@params['time'] ? (Time.now - Time.parse(@params['time']))/60 : @time_interval
	end

	# Add timestamp to the logfile in the format:
	# time~2014-01-01 12:16:09 +0530
	# If args[:old] is true, use an old Timestamp. This case is only required when the file is being run the first time.
	def logTime(args = {:old => false})
		time = args[:old] ? Time.at(0) : @current_time
		File.open(@file, 'w'){|f| f.write('time~' + time.to_s + "\n") }
		File.open(@file, 'a') {|f| f.write('modhash~' + @params['modhash'].to_s + "\n" + 'cookies~' + @params['cookies'].to_s + "\n") }
	end

	# Log the time and ID of the latest comment & post fetched from Reddit. If no new comments or posts were fetched, log the one's in @param
	def logLastCrawled(comments, posts)
		return false if DEBUG
		# Now that we've read the old params and done, write the current timestamp to file.
		logTime
		# Log latest comment and post IDs
		# comment_id = comments.empty? ? @params['last_comment'] : comments.first['data']['name']
		post_id = posts.empty? ? @params['last_post'] : posts.first['data']['name']
		File.open(@file, 'a') {|f| f.write('last_post~' + post_id.to_s) }
	end

	# Get page using net/http.
	# parse json
	# return only relevant data
	def getJSON(domain, url)
		page = Net::HTTP.get_response(domain,url)
		JSON.parse(page.body)
	end

	def linkExtract(raw_reddit_html)
		raw_reddit_html = raw_reddit_html.to_s
		return [] if raw_reddit_html.length < 2
		html = Nokogiri::HTML.parse(CGI.unescapeHTML(raw_reddit_html))
		html.css('a').map { |link| link['href'] }
	end

	# Extract array of links in a comment/self-post/thread
	# Returns an array of GIF links
	def gifLinkExtract(links)
		gif_links = []
		links.each do |link|
			if link.include?('imgur.com')
				gif_links << extractImgurGif(link)
			elsif link.downcase.include?('.gif')
				gif_links << link
			end
		end
		gif_links.compact
	end

	def extractImgurGif(link)
		match_result = link.match(/imgur\.com\/([\w\d]+)(\.(jpg|gif|png|JPG|GIF|PNG))?/)
		unless match_result.nil?
			imgur_response = open(link)
			return "http://i.imgur.com/#{match_result[1]}.gif" if imgur_response.content_type == 'image/gif'
		end
		nil
	end

	# Accepts unique gfycat name and returns a complete URL.
	def genGfyLink(gfyname)
		gfyname ? "http://gfycat.com/#{gfyname}" : ''
	end

	# Generate the comment body as markdown text to be posted on reddit.
	# Accepts an array hashes, containing of gfy links.
	def generateCommentBody(links, author)
		if links.length == 1
			unless links.first['gifSize'].nil?
				gif_size = links.first['gifSize'].to_i
				gfy_size = links.first['gfysize'].to_i
				percent = ((gfy_size.to_f/gif_size)*100).to_i.to_s + "%"
				stats = "GIF size:#{number_to_human_size(gif_size)} | HTML5 size:#{number_to_human_size(gfy_size)} | HTML5 is #{percent} of the original GIF\n"
			end

			if links.first[:imgur_link]
				link = links.first[:gifv_link]
			else
				link = genGfyLink(links.first['gfyname'])
			end
			comment = <<BODY
Hi #{author},\s\s
Your GIF submission has been removed because we've decided to move on from these ancient, slow-loading GIFs to blazing-fast HTML5.

Feel free to re-submit this HTML5 version of your GIF: **#{link}**\s\s
#{stats.to_s}

---

^(**About HTML5 videos**: GIFs is an old format meant for small images with short loops. They are not for big long video clips as they are often now being misused for, and as a result they're often bloated and take forever to load. Browsing woahdude has become intolerable on some devices because of unnecessarily enormous GIFs.)

^(On the other hand, HTML5 is almost 5% the file size of a GIF. It loads way faster and you can pause, move frame-by-frame or reverse it with one click.) [^Read ^More](http://www.reddit.com/r/woahdude/comments/266gf8/its_2014_can_we_stop_using_gifs_already/)

BODY
			comment
		end
	end

	# If you use the ID of a deleted comment/post on to fetch new comment/posts made "after" that date, it wont show any new comments/posts.
	# TL;DR - bot goes for a toss. So this function fixes it by checking if the item (comment or post) has been deleted. Call this everytime 0 links are found.
	# Get item info by using this URL: http://www.reddit.com/r/all/api/info.json?id=t3_1us4t4
	# Check the author. If it is [deleted], return the id of first post/comment from sub/new else return the
	# https://github.com/awkdev/gfy_bot/issues/5
	def checkDeletedItem(id)
		# Check if item is a post or comment
		is_post = id.include?('t1_') ? false : true
		puts "Didn't find any new #{is_post ? 'post' : 'comment' } so it's probably an ID issue. Getting new ID..."

		sleep(2)
		url = "/r/#{@subreddits.join('+')}/"
		if is_post # this is a post
			url += 'new.json?limit=1'
		else # this is a comment
			url += 'comments.json?limit=1'
		end
		latest_item = getJSON('www.reddit.com',url)
		latest_item = latest_item['data']['after']
		if is_post
			@params['last_post'] = latest_item
		else
			@params['last_comment'] = latest_item
		end
		puts 'Logging latest_item ' + latest_item
	end

	# Generate Hawk Mac to authenticate to gfycat.com/api
	def getHawkMac(link)
		options = {
				:credentials =>
						{
								:id => @hawk_id,
								:key => @hawk_key,
								:algorithm => "sha256"
						},
				:method => "GET",
				:host => "api.gfycat.com",
				:port => 80,
				:request_uri => "/transcode?fetchUrl=#{link}"
		}
		Hawk::Client.build_authorization_header(options)
	end

	# Main function which uploads to gfycat using HAWK, and if that fails, using normal API. returns gfy hash
	def uploadToGfycat(gif)
		mac = getHawkMac(gif)
		hawk_URL = 'http://api.gfycat.com/transcode?fetchUrl=' + CGI::escape(gif)
		getGfy = HTTParty.get(hawk_URL, :headers => { 'Authorization' => mac })
		if getGfy.response.header.code.to_i == 200
			JSON.parse(getGfy.response.body)
		else
			puts 'Hawk Authentication failed with URL: '+ gif
			normal_URL = @gfyurl + CGI::escape(gif)
			getJSON(@gfydom, normal_URL)
			sleep(20)
		end
	end

	# Main handler function which handles the bot and links all functions together
	# ============================================================================
	# A) LINKS & SELF POSTS
	# 1. Crawl the subs for links --- /r/sub1+sub2/new.json?before=id
	# 2. If link post send to -> gifExtract as array (extend to imgur albums in future)
	# 3. All above return an array of gif links. Save it in @links along with their IDs so we can post a reply

	# Once we have @links ready, start uploading to gfycat.com using the API and post reply to Reddit as comment
	def start
		if check_time_interval < @time_interval
			puts 'Exiting bot because it ran less than ' + @time_interval.to_s + ' minutes ago.'
			exit!
		end

		reddit = 'www.reddit.com'
		subs = @subreddits.join('+')

		# URL for Posts
		url = "/r/#{subs}/new.json?limit=#{@limit}"
		# url += "&before=#{@params['last_post']}" unless @params['last_post'].nil?
		# GET Posts
		posts = getJSON(reddit, url)
		posts = posts['data']['children']
		# If it fetches 0 posts, then it means something is def wrong with the @params['last_post'], so just get a new id
		# checkDeletedItem(@params['last_post']) if posts.empty?

		# Log current time
		@current_time = Time.now
		puts 'Starting crawl at: ' + @current_time.to_s

		# Process posts
		posts.each do |post|
			post = post['data']
			links = []

			nsfw = false
			unless post['is_self']
				links.concat(gifLinkExtract([post['url']]))
				nsfw = @nsfw_subs.include?(post['subreddit'].downcase)
			end

			@links << {
					:links => links,
					:id => post['name'],
					:subreddit => post['subreddit'],
					:nsfw => nsfw,
					:author => post['author']
			} unless links.empty?
		end

		puts 'Found ' + @links.length.to_s + '/' + (posts.length).to_s + ' links on /r/' + subs

		logLastCrawled(nil, posts)

		# return false
		# Loop through the links now
		@links.each do |link|
			# NOTICE that even link is a hash at this moment, because one comment can have more than one GIFs
			# links = {
			#		:links => ['http...', 'http...']
			#		:id => 't1_c3c3c3c',
			#		:subreddit => 'AskReddit'
			# 		:nsfw => true
			# }
			gfy_links = []
			link[:links].each do |gif|
				if gif.match(/^.*imgur\.com\/[\w\d]+\.gif$/)
					gfy_links << {
							imgur_link: true,
							gifv_link: gif + 'v'
					}
					next
				end
				gfy = {}
				gfy = uploadToGfycat(gif)  unless DEBUG
				if gfy['error']
					puts "Couldn't upload #{gif}: #{gfy.to_s}"
				else
					gfy_links << gfy
				end
				sleep(7)
			end
			unless gfy_links.empty?
				comment = generateCommentBody(gfy_links, link[:author])
				if !comment
					puts "Couldn't generate comment for #{link[:id]}. Skipping..."
					next
				end
				puts 'Posting comment to ' + link[:id]
				reddit_comment = @gfybot.comment(comment, link[:id])  unless DEBUG
				@gfybot.remove(link[:id])
				reddit_comment_id = nil
				begin
					reddit_comment_id = reddit_comment['json']['data']['things'].first['data']['id']
				end
				@gfybot.distinguish(reddit_comment_id) unless reddit_comment_id.nil?
				sleep(5)
			end
		end
		puts 'All done. Exiting. BuhBuye!'
	end

	def getlinks
		@links
	end
end
# ====== CLASS ENDS ========
# List of subs
subs = 'thisismyspace'
nsfw_subs = 'tittydrop'

# Params for the bot
options = {
		:username => 'gfy_bot',
		:password => ENV['GFY_BOT_REDDIT_PASSWORD'],
		:hawk_id => '52cfadf2a9206',
		:hawk_key => ENV['GFYCAT_HAWK_KEY'],
		:subreddits	=> subs.split(','),
		:nsfw_subs => nsfw_subs.downcase.split(',')
}
gfy_bot = WoahdudeBot.new(options)
gfy_bot.start