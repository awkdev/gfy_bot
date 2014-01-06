class GfyBot
	# List of required Gems
	require 'snoo'
	require 'json'
	require 'nokogiri'
	require 'net/http'
	require 'cgi'
	require 'time'
	require 'filesize'

	# ====================================
	# NOTHING WILL BE UPLOADED TO GFYCAT OR
	# POSTED TO REDDIT IF DEBUG IS SET TO TRUE.
	# =====================================
	DEBUG = true

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
		@time_interval = args[:time_interval] || 5
		@subreddits = args[:subreddits] || ['thisismyspace']
		@limit = 100 # no. of posts/comments to fetch in one go

		# Name of the bot using Snoo Reddit API wrapper
		@gfybot = Snoo::Client.new

		# GFY Upload URL using the API. Returns a JSON
		# http://upload.gfycat.com/transcode?fetchUrl=http%3A%2F%2Fi.imgur.com%2FCXE9FRs.gif
		@gfydom = 'upload.gfycat.com'
		@gfyurl = '/transcode?fetchUrl='

		# The logger file contains runtime details from the last crawl. This function reads the file and saves imp details in params hash
		@file = 'logfile.txt'
		@params = {}
		@current_time = nil
		initializeParams

		# links is an array of hashes containing the links in posts/comments and their IDs so the bot can reply to them later
		# @links = [
		#		{
		#				:links => ['http://imgur.com/test.gif'],
		#				:id => 't1_c3c3c3c3'
		#		},
		#		{
		#				:links => ['http://imgur.com/test2.gif'],
		#				:id => 't2_c3c3c3c3'
		#		}
		# ]
		@links = []
	end

	# Reads the logfile saved on disc which contains few runtime details gathered from the last run of the bot. If the file does not exist, create it.
	def initializeParams
		# Check if the file exists. If yes: read the params, if not: create it and log an OLD timestamp to it so we start crawling now.
		File.exist?(@file) ? readLogFile : logTime({:old => true})
	end

	# The logfile contains 3 lines, both a key/value pair separated by a tilde ( ~ ) sign. So we extract it into a ruby hash for our use
	# ------- raw logfile --------
	# time~2014-01-01 12:16:09 +0530
	# last_comment~t1_c3c3c3c3
	# last_post~t3_cc2c2c2
	# ----- after extraction it becomes ----------
	# params = {
	#	:time => '2014-01-01 12:16:09 +0530',
	#	:last_comment => 't1_c3c3c3c3'
	#	:last_post => 't3_cc2c2c2'
	# }
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
	end

	# Log the time and ID of the latest comment & post fetched from Reddit. If no new comments or posts were fetched, log the one's in @param
	def logLastCrawled(comments, posts)
		# Now that we've read the old params and done, write the current timestamp to file.
		logTime
		# Log latest comment and post IDs
		comment_id = comments.empty? ? @params['last_comment'] : comments.first['data']['name']
		post_id = posts.empty? ? @params['last_post'] : posts.first['data']['name']
		File.open(@file, 'a') {|f| f.write('last_comment~' + comment_id.to_s + "\n" + 'last_post~' + post_id.to_s) }
	end

	# Login the bot to Reddit using Snoo API
	def login
		if @gfybot.log_in(@username, @password)
			puts 'Logged in to Reddit successfully'
			true
		else
			puts 'Could not login to Reddit. Please check the username/pass/internetconnection and try again'
			false
		end
	end


	# Get page using net/http.
	# parse json
	# return only relevant data
	def getJSON(domain, url)
		page = Net::HTTP.get_response(domain,url)
		JSON.parse(page.body)
	end

	#
	def linkExtract(raw_reddit_html)
		raw_reddit_html = raw_reddit_html.to_s
		return [] if raw_reddit_html.length < 2
		html = Nokogiri::HTML.parse(CGI.unescapeHTML(raw_reddit_html))
		html.css('a').map { |link| link['href'] }
	end

	# Extract array of links in a comment/self-post/thread
	# Returns an array of GIF links
	def gifLinkExtract(links)
		# Only return links which end in .gif and do not contain gfycat.com
		links.select {|link| link.downcase.include?('.gif') && link.include?('gfycat.com')==false }
	end

	# Accepts unique gfycat name and returns a complete URL.
	def genGfyLink(gfyname)
		gfyname ? "http://gfycat.com/#{gfyname}" : ''
	end

	# Generate the comment body as markdown text to be posted on reddit.
	# Accepts an array hashes, containing of gfy links.
	def generateCommentBody(links)
		if links.length == 1
			comment = "GFY link: [gfycat.com/#{links.first['gfyname']}](#{genGfyLink(links.first['gfyname'])})"
			gif_size = 'GIF size: ' + Filesize.from(links.first['gifSize'].to_s + 'B').pretty
			gfy_size = 'GFY size:' + Filesize.from(links.first['gfysize'].to_s + 'B').pretty
		else
			comment = []
			gif_size = 0
			gfy_size = 0
			links.each_with_index do |link, index|
				comment << "[GFY link #{index+1}](#{genGfyLink(link['gfyname'])})"
				gif_size += link['gifSize'].to_i
				gfy_size += link['gfysize'].to_i
			end
			gif_size = 'Combined GIF size: ' + Filesize.from(gif_size.to_s + 'B').pretty
			gfy_size = 'Combined GFY size: ' + Filesize.from(gfy_size.to_s + 'B').pretty
			comment = comment.join(' | ')
		end

		footer = <<FOOTER


---

^(#{gif_size}) ^| ^(#{gfy_size}) ^| [^(~ About)](http://www.reddit.com/r/gfybot)
FOOTER
		comment + footer
	end

	# Main handler function which handles the bot and links all functions together
	# ============================================================================
	# A) LINKS & SELF POSTS
	# 1. Crawl the subs for links and self posts --- /r/sub1+sub2/new.json?before=id
	# 2. If link post send to -> gifExtract as array (extend to imgur albums in future)
	# 3. If self post get self_html and send to -> linkExtract then to -> gifExtract
	# 4. All above return an array of gif links. Save it in @links along with their IDs so we can post a reply

	# B) COMMENTS
	# 1. Crawl the subs for comments
	# 2. Then follow steps 3 & 4 from above

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
		url += "&before=#{@params['last_post']}" unless @params['last_post'].nil?
		# GET Posts
		posts = getJSON(reddit, url)
		posts = posts['data']['children']

		# URL for comments
		url = "/r/#{subs}/comments.json?limit=#{@limit}"
		url += "&before=#{@params['last_comment']}" unless @params['last_comment'].nil?
		# GET Comments
		comments = getJSON(reddit, url)
		comments = comments['data']['children']

		# Log current time
		@current_time = Time.now

		# Process posts
		posts.each do |post|
			post = post['data']
			links = []

			if post['is_self']
				links.concat(gifLinkExtract(linkExtract(post['selftext_html'])))
			else
				links.concat(gifLinkExtract([post['url']]))
			end

			@links << { :links => links, :id => post['name'] } unless links.empty?
		end

		# Process comments
		comments.each do |comment|
			comment = comment['data']
			links = gifLinkExtract(linkExtract(comment['body_html']))
			@links << { :links => links, :id => comment['name'] } unless links.empty?
		end

		puts 'Found ' + @links.length.to_s + ' links on /r/' + subs

		if @links.empty?
			# Log the last crawled comment and post, so next time we ONLY get the posts and comments posted after that.
			logLastCrawled(comments, posts)
		else
			if login
				# Log the last crawled comment and post, so next time we ONLY get the posts and comments posted after that.
				logLastCrawled(comments, posts)
			else
				exit!
			end
		end

		# Loop through the links and post comments now
		@links.each do |link|
			# NOTICE that even link is a hash at this moment, because one comment can have more than one GIFs
			# links = {
			#		:links => ['http...', 'http...']
			#		:id => 't1_c3c3c3c'
			# }
			gfy_links = []
			link[:links].each do |gif|
				upload_url = @gfyurl + CGI::escape(gif)
				gfy = {}
				gfy = getJSON(@gfydom, upload_url)  unless DEBUG
				gfy_links << gfy
				# TODO: Timer
				sleep(10)
			end
			comment = generateCommentBody(gfy_links)
			puts 'Posting comment to ' + link[:id]
			@gfybot.comment(comment, link[:id])  unless DEBUG
			sleep(5)
		end
		puts 'All done. Exiting. BuhBuye!'
	end

	def getlinks
		@links
	end
end

options = {
		:username => 'gfy_bot',
		:password => 'xxxxxxxxxxxx',
}
gfy_bot = GfyBot.new(options)

links = gfy_bot.start

puts 'Done'