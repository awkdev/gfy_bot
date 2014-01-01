require 'snoo'
require 'json'
require 'nokogiri'
require 'net/http'
require 'cgi'
require 'time'

# Initialize the Snoo Client
reddit = Snoo::Client.new

# CONFIG BLOCK
username = 'gfy_bot' # ADD YOUR BOT'S reddit Username
password = 'xxxxxxxxxxxx' # ADD YOUR BOT'S Username
subreddits = ['india', 'bakchodi'] # ARRAY of subs to crawl
time_interval = 5 # Time interval between 2 consecutive crawls (in minutes)
file = 'latest.txt' # This file MUST exist (just a blank file is fine) in order for the bot to work.
#file = 'latest.txt' # For local testing
# TODO 1: Optimize the need to have a latest.txt file and have it created automatically

# Log in
reddit.log_in username, password


# TODO 2: Optimize generateCommentOne & generateComment methods
# Function to generate comment body with gfycat links and ordered list in case there is just ONE link.
def generateCommentOne(link, i)
  gfy_link = 'http://gfycat.com/fetch/'+link
  output = <<END
[gfycat](#{gfy_link})\s\s

END
  output
end
# Function to generate comment body with gfycat links and ordered list if there are multiple links.
def generateComment(link, i)
  gfy_link = 'http://gfycat.com/fetch/'+link
  output = <<END
#{i} [gif #{i}](#{gfy_link})\s\s

END
  output
end

# 1. Loop through the subs defined in config and fetch comments from reddit.com/r/sub/comments.json URL.
# 2. Get the ID of last comment which was pulled
# 3. Loop through all the comments, get links via Nokogiri, check if they have one or more link tags.
# 4. Loop through link tags, see if they are GIF images via gsub
# 5. Generate GFYCAT comment body and reply to the original comment
unless subreddits.empty?

  puts 'Running at ' + Time.now.to_s

  # Read last crawled comment and time
  # Gives us a hash like this
  # last_id_obj = {
  #    :time => '2014-01-01 12:16:09 +0530',
  #    :last_comment => 't1_c3c3c3c3'
  # }
  last_id_obj = {}
  File.readlines(file).each do |line|
    sub = line.split('~').first
    code = line.split('~').last
    code.gsub!(/(.*)\n?$/,'\1')
    last_id_obj[sub] = code
  end

  ##############  OPENSHIFT HACK #############
  # Hack specific to OPENSHIFT cron cartridge to check time difference between when the script was last run and now.
  time_diff = time_interval
  time_diff = (Time.now - Time.parse(last_id_obj['time']))/60 if last_id_obj['time']
  if time_diff < time_interval
    puts 'Exiting script since it ran too recently'
    exit!
  end
  last_id_obj.delete('time')
  ###### REMOVE IF NOT USING OPENSHIFT #########

  # Empty the file.
  File.open(file, 'w'){|f| f.write('time~' + Time.now.to_s + "\n") }

  sub = subreddits.join('+')
  sub_url = '/r/'+sub+'/comments.json?limit=100'
  # append LAST comment id which was pulled from latest.txt file, to fetch ONLY comments posted after that date. DO THIS ONLY IF A CODE WAS actually pulled
  sub_url += '&before='+last_id_obj['last_comment'] unless last_id_obj['last_comment'].nil?

  # Get json using net/http
  page = Net::HTTP.get_response('www.reddit.com',sub_url)
  # Parse it
  page_json = JSON.parse(page.body)
  comments = page_json['data']['children']

  puts 'Found ' + comments.length.to_s + ' comments on /r/' + sub
  # Loop through the comments
  comments.each do |comment|
    # Use cgi to unescape and nokogiri to extract links
    comment_html = Nokogiri::HTML.parse(CGI.unescapeHTML(comment['data']['body_html']))
    all_links = comment_html.css('a').map { |link| link['href'] }
    # GIF links stored in links variable
    links = all_links.select {|link| link.downcase.include?('.gif') && link.include?('gfycat.com')==false }

    new_comment = ''
    links.each_with_index do |link, index|
      #puts link
      if links.length > 1
        new_comment += generateComment(link, index+1)
      else
        new_comment += generateCommentOne(link, index+1)
      end
    end
    new_comment += "\n*****\n\n*small size GFY for faster viewing [(!)](http://gfycat.com/about)*"

    # Reply to comment if GIF links were found
    unless links.empty?
      puts 'posting comment to ' + comment['data']['name']
      # POST comment reply
      response = reddit.comment(new_comment, comment['data']['name'])
      puts response[:errors].to_s unless response[:errors].nil?
      sleep(2)
    end
  end

  # Store the latest comment's id in a file, so we can fetch new comments posted after that next time. One each line
  # Format subreddit_name~comment_id
  # eg:
  # askreddit~t1_yaa7s7wk

  # Last comment id if no new comments on sub
  if comments.empty?
    last_comment_id = last_id_obj[sub] || ''
  else
    last_comment_id = comments.first['data']['name']
  end

  File.open(file, 'a') {|f| f.write('last_comment~' + last_comment_id + "\n") }
  sleep(5)
end
puts 'All done, exiting now...'