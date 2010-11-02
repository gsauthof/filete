#!/usr/bin/env ruby -KU

# 2010, Georg Sauthoff, gsauthof@techfak.uni-bielefeld.de
#                       gsauthof@sdf.lonestar.org
# License: GPL v3+

require 'optparse'
require 'pathname'

require 'logsplit'

Log = Logsplit::Logger.new

opts = Struct.new(:ttfile, :tempdir, :filter,
                 :fetch_details,
                 :mbfile, :ttdelete).new

opts.ttfile = nil
opts.tempdir = Pathname.new('tmp')
opts.filter = '.'
opts.fetch_details = false

oparser = OptionParser.new do |o|
  o.banner = "Usage: main [options]"
  o.on("--ttlogin FILE", "login credentials for tt") do |x|
    opts.ttfile = x
  end
  o.on("--temp DIR", "temp files directory") do |x|
    opts.tempdir = Pathname.new(x)
  end
  o.on("--filter REGEX", "tt book filter expression") do |x|
    opts.filter = x
  end
  o.on("--fetch-details", "fetch tt details pages but reuse index pages") do |x|
    opts.fetch_details = true
  end
  o.on("--mblogin FILE", "login credentials for mbdb") { |x|
    opts.mbfile = x
  }
  o.on("--ttdelete FILE", "delete books from tt (login creds)") { |x|
    opts.ttdelete = x
  }
end

require 'iconv'

def toutf(s)
  Iconv.conv('UTF-8', 'latin1', s)
end

def wait
  sleep(1.0 + 2.0 * rand)
end

def get(conn, url)
  wait
  conn.get(url)
end

def set_ua(conn)
  conn.user_agent = 'Mozilla/5.0 (X11; U; Linux x86_64; en-US; rv:1.9.2.7) Gecko/20100720 Firefox/3.6.7'
end

def write_file(name, cont)
  f = File.new(name, 'wb')
  r = f.syswrite(cont)
  # r > size because of encoding issues?
  if r < cont.size
    Log.fatal("Only written #{r} of #{cont.size} bytes of ${name}") ; raise "Fatal"
  end
  f.flush
  f.close
end

def prefix(url)
  x = url
  if x =~ /^(.+)\/$/
    x = $1
  end
  /\/([^\/]+)$/.match(x)
  d = $1.strip
  if d == nil || d == ''
    Log.fatal("URL parse error of: #{url}") ; raise "Fatal"
  end
  d
end

def write_url(tempdir, url, cont)
  Log.info("Writing: #{url}")
  d = prefix(url)
  write_file(tempdir + d, cont)
end


def read_user(name)
  f = open(name)
  a = Array.new
  f.each do |line|
    x = line.strip
    a << x
  end
  f.close
  r = Struct.new(:name, :password).new
  r.name = a[0]
  r.password = a[1]
  r
end

require 'mechanize'

def ttlogin(user)
  Log.info "Login into tt as: #{user.name}"
  a = Mechanize.new
  set_ua(a)
  g = get(a, 'http://www.tauschticket.de')
  l = g.form_with(:name => 'login') do |form|
    form.login = user.name
    form.passwort = user.password
  end.submit
  if l.meta.first.uri.to_s != 'http://www.tauschticket.de/myHomepage/?nt=' + user.name
    Log.fatal("Could not login with user #{user.name} ! Response page is:\n#{toutf l.body}") ; raise "Fatal"
  end
  r = Struct.new(:handle, :page).new
  r.handle = a
  r.page = l
  r
end


def ttlogout(conn)
  Log.info "logout from tt"
  get(conn.handle, 'http://www.tauschticket.de/logout/')
end

def ttdelete(conn, list)
  list.each { |entry|
    Log.info("Deleting: #{entry.title}")
    a = get(conn.handle, "/myTAngebotLoeschen/?angId=#{entry.id}")
    if a.link_with(:text => 'NEIN') == nil
      Log.error("Error deleting. Page body is:\n#{toutf a.body}")
    end
    b = get(conn.handle, "/myTAngebotLoeschenOK/")
    #puts b.body
  }
end

# nokogiri DOM too slow, SAX to broken ...
# WTF?!?
# SAX stops calling begin_element after title element ...

Entry = Struct.new(:id, :url, :img, :title, :author, :date,
                  :publisher, :year, :pages, :isbn, :medium, :language,
                  :cats, :content, :desc, :bigimg)

# WTF?!? with iconv segfaults in nokogiri content loop (with 1.8.7)
def conv(s)
  #s.gsub("\337", "ß").gsub("\344", "ä").gsub("\374", "ü").gsub("\366", "ö")
  s
end


def ttparsebooks(page, list)
  Log.info 'Parsing tt book listing'
  state = 0
  x = Entry.new
  page.each do |tline|
    line = Iconv.conv('UTF-8', 'latin1', tline)
    if line =~ /class="main_content_v2"/
      state = 1
      x = Entry.new
      next
    end
    if state == 1 && line =~ /href="([^"]+)".*img.*src="([^"]+)"/
      state = 2
      x.img = $2
      x.url = $1
      x.url =~ /_([0-9]+)\/$/
      x.id = $1
      next
    end
    if state == 2 && line =~ /class="offer_title"><a[^>]+>([^>]+)<\//
      state = 3
      x.title = conv($1)
      next
    end
    if state == 3 && line =~ /class="offer_text">([^<]+)</
      state = 4
      x.author = conv($1)
      next
    end
    if state == 4 && line =~ /class="offer_text">([^<]+)</
      state = 5
      next
    end
    if state == 5 && line =~ /class="offer_text">Eingestellt am:([^<]+)</
      state = 6
      x.date = $1
      list << x
      next
    end
  end
  list
end

def ttfetchbooks(conn, tempdir)
  Log.info "Fetching tt book listing"
  g = get(conn.handle, 'http://www.tauschticket.de/myTauschangebote/?pg=buch')
  
  write_file(tempdir + 'ttbook', g.body)

  list = Array.new
  ttparsebooks(g.body.lines, list)

  i = 1
  loop do
    i+=1
    # WTF?!?
    # g.links_with(:text => %r{/weiter.*/} )
    # does not work
    # but links_with(:href => %r{/.*/} ) does ...
    link = nil
    g.links.each do |l|
      if l.text =~ /^weiter/ && l.href =~ /^\/myTauschangebote/
        link = l
        break
      end
    end
    if link == nil
      break
    end
    Log.info('Fetching next page')
    g = link.click
    write_file(tempdir + ('ttbook_' + i.to_s), g.body)
    ttparsebooks(g.body.lines, list)
  end
 
  list
end

def ttfetchbooksfiles(dir)
  Log.info "Reading directory: #{dir}"
  list = []
  # not using Dir[dir.to_s + '/*'].each because of path-sep agnosticism
  Dir.foreach(dir) do |e|
    if e =~ /^ttbook/
      f = open(dir + e)
      ttparsebooks(f, list)
      f.close
    end
  end
  list
end

def ttprint(list)
  list.each do |entry|
    puts entry.title
    puts entry.id
  end
end

def ttfilter(list, ex)
  Log.info "Filtering list with: #{ex}"
  r = Array.new
  list.each do |entry|
    s = 'author: ' + entry.author + '|title: ' + entry.title + '|date: ' + entry.date
    if Regexp.new(ex).match(s)
      r << entry
    end
  end
  r
end

def ttparsebookdetails(cont, entry)
  Log.info "Parsing tt book details for: #{entry.title}"
  f = Nokogiri.HTML(cont)
  i = f.search('//div[@class="detail_listing"]')
  j = f.search('//div[@class="detail_listing_text"]')
  l = i.zip(j)
  if l[1][0].text.strip != 'Verlag:'; raise 'Parse Error' end
  entry.publisher = l[1][1].text.strip
  if l[2][0].text.strip != 'Jahr:'; raise 'Parse Error' end
  entry.year = l[2][1].text.strip
  if l[3][0].text.strip != 'Seitenzahl:'; raise 'Parse Error' end
  entry.pages = l[3][1].text.strip
  if l[4][0].text.strip != 'ISBN:'; raise 'Parse Error' end
  entry.isbn = l[4][1].text.strip
  if l[5][0].text.strip != 'Medium:'; raise 'Parse Error' end
  entry.medium = l[5][1].text.strip
  if l[6][0].text.strip != 'Sprache:'; raise 'Parse Error' end
  entry.language = l[6][1].text.strip

  entry.cats = []
  c = f.search('//div[@class="detail_category"]').text
  c.split('Bücher').each do |e|
    x = e.gsub(/\302\240/, '').strip
    if x =~ /^>/
      entry.cats << x
    end
  end

  d = f.search('//div[@class="detail_description"]/following-sibling::div[1]/child::text()')
  entry.desc = d[0].text
  entry.content = ''
  d[1, d.size].each do |e|
    entry.content << e.text
  end

  urls = []
  f.search('//img').each do |e|
    u = e.attributes['src'].text
    if u =~ /\/artikel\//
      urls << u
    end
  end
  entry.bigimg = urls.last
  [ entry.bigimg ]
end

def ttfetchbooksdetails(list, tempdir)
  a = Mechanize.new
  set_ua(a)
  list.each do |entry|
    Log.info "Fetch book details for: #{entry.title}"
    img = get(a, entry.img)
    write_url(tempdir, entry.img, img.body)

    g = get(a, entry.url)
    write_url(tempdir, entry.url, g.body)

    urls = ttparsebookdetails(g.body, entry)
    urls.each do |u|
      x = get(a, u)
      write_url(tempdir, u, x.body)
    end
  end
end

def pretty(e)
  puts "  Title: #{e.title} Author: #{e.author}"
  puts "  ISBN: #{e.isbn} Publisher: #{e.publisher}"
  puts "  Medium: #{e.medium} Language: #{e.language}"
  puts "  Year: #{e.year} Pages: #{e.pages}"
  puts "  Cats: #{e.cats}"
  puts "  Desc: #{e.desc}"
  puts "  Content: #{e.content}"
  puts "\n\n"
end

require 'ttcats'

def ttfetchbooksdetailsfiles(list, tempdir)
  list.each do |entry|
    Log.info "Reading files for book: #{entry.title}"
    img = File.new(tempdir + prefix(entry.img), 'rb')
    f = File.new(tempdir + prefix(entry.url), 'r')
    urls = ttparsebookdetails(f, entry)
    big = File.new(tempdir + prefix(urls[0]), 'rb')
    pretty(entry)
    entry.cats.each do |c|
      Log.info("  Map #{c} => #{TTcats::TTMB[c]}")
    end
  end
end

def mblogin(user)
  Log.info "Login into mb as: #{user.name}"
  a = Mechanize.new
  set_ua(a)
  g = get(a, 'http://www.meinbuch-deinbuch.de/')
  l = g.form_with(:name => 'logon') do |form|
    form.user = user.name
    form.pwd = user.password
  end.submit
  if l.link_with(:text => "LOGOUT") == nil
    Log.fatal("Could not login with user #{user.name} ! Response page is:\n#{toutf l.body}") ; raise "Fatal"
  end
  r = Struct.new(:handle, :page).new
  r.handle = a
  r.page = l
  r
end

def mblogout(conn)
  Log.info "Logout from mb"
  conn.page.link_with(:text => "LOGOUT").click
end

TT2MB_medium = {
  'Taschenbuch' => 'TB',
  'Softcover'   => 'SC',
  'Hardcover'   => 'HC',
  'Hörbuch MC'  => 'HB',
  'Hörbuch CD'  => 'HB',
}

TT2MB_language = {
  'Deutsch' => 'de',
  'Englisch' => 'en',
  'Französisch' => 'fr',
  'Spanisch' => 'so',
  'Portugiesisch' => 'so',
  'Italienisch' => 'it',
  'Türkisch' => 'so',
  'Niederländisch' => 'nl',
  'Dänisch' => 'so',
  'Schwedisch' => 'so',
  'Finnisch' => 'so',
  'Norwegisch' => 'so',
  'Polnisch' => 'so',
  'Russisch' => 'ru',
  'Chinesisch' => 'so',
  'Japanisch' => 'so',
  'Sonstige' => 'so',
}

def mbinsert(conn, entry, tempdir)
  ex = {}
  begin
    file = File.new(tempdir + 'mbinserted', 'r')
    file.each { |l|
      ex[l.strip] = 1
    }
    file.close
  rescue
  end
  if ex[entry.id] != nil
    Log.warn("Already inserted: #{entry.title} (#{entry.id})")
    return
  end
  if entry.content.size < 30
    if entry.title =~ /^Was ist/
      entry.content = "Aus der bekannten Was ist was Reihe. Die Sachbuchreihe halt."
    else
      Log.warn "Description of #{entry.title} too short (<30): #{entry.content}"
      return
    end
  end

  # http://www.meinbuch-deinbuch.de/buchtausch/private/buch_einstellen.php
  p = conn.page.link_with(:text => "Bücher einstellen").click
  f = p.form_with(:name => 'f1') do |form|
    form.isbn = entry.isbn
  end.submit

  # final = f.form_with(:name => 'final')
  final = f.form('final')
  if final == nil
    Log.error "Could not find form in reply:\n#{toutf f.body}"
    return
  end

  overwrite = false
  if entry.isbn == '' || entry.isbn == 'k.A.'
    overwrite = true
  end

  # instead of f.form('final').field('zustand').value etc.
  f.form('final') { |x|
    if overwrite
      x.isbn = ''
    end
    if x.titel == "" || overwrite
      x.titel = entry.title
    end
    if x.autor == "" || overwrite
      x.autor = entry.author
    end
    if x.jahr == "" || overwrite
      x.jahr = entry.year
    end
    if x.seiten == "" || overwrite
      x.seiten = entry.pages
    end
    if x.verlag == "" || overwrite
      x.verlag = entry.publisher
    end
    if x.zustand == "" || overwrite
      x.zustand = entry.desc
    end
    if x.kommentar == "" || overwrite
      x.kommentar = entry.content
      #x.kommlen = entry.content.size
    end

    if x.kat == "" || x.kat == 'false' || overwrite
      if entry.cats.empty?
        Log.warn("Using empty cat")
        x.kat = '14|124' # Bell & Romane -> Sonstiges
      else
        v = TTcats::TTMB[entry.cats.first]
        if v
          x.kat = v[0]
        else
          Log.warn("Cannot find cat mapping for: #{entry.cats.first}")
          x.kat = '14|124' # Bell & Romane -> Sonstiges
        end
      end
    end
    if x.medium == "" || x.medium == '0'|| overwrite
      v = TT2MB_medium[entry.medium]
      if v
        x.medium = v
      else
        Log.warn("Cannot find medium mapping for: #{entry.medium}")
        x.medium = 'TB'
      end
    end
    v = TT2MB_language[entry.language]
    if v
      x.sprache = v
    else
      Log.warn("Cannot find language mapping for: #{entry.language}")
      x.sprache = 'de'
    end
  }

  if entry.bigimg != ''
    final.file_upload('bild').file_name = prefix(entry.bigimg)
    final.file_upload('bild').mime_type = 'image/jpeg'
    File.open(tempdir + prefix(entry.bigimg), 'rb') { |f| 
      final.file_upload('bild').file_data = f.read
    }
  end

  a = final.submit

  body = toutf(a.body)
  if body =~ /Einsteller:/
    file = File.new(tempdir + 'mbinserted', 'a')
    file.puts(entry.id)
    file.flush
    file.close
  else
    Log.error "Error posting entry: #{entry.title} page body is:\n#{body}"
  end
end

require 'fileutils'

oparser.parse!(ARGV)

if ! ARGV.empty?
  puts 'Seen spurious arguments:'
  ARGV.each do |a|
    puts "   #{a}"
  end
  puts ''
  exit 1
end

FileUtils.mkdir_p opts.tempdir

list = []

if opts.ttfile
  user = read_user(opts.ttfile)
  conn = ttlogin(user)
  list = ttfetchbooks(conn, opts.tempdir)
  list = ttfilter(list, opts.filter)
  ttprint(list)

  ttfetchbooksdetails(list, opts.tempdir)
  
  ttlogout(conn)
end

if opts.ttfile == nil
  list = ttfetchbooksfiles(opts.tempdir)
  list = ttfilter(list, opts.filter)
  ttprint(list)

  if opts.fetch_details
    ttfetchbooksdetails(list, opts.tempdir)
  else
    ttfetchbooksdetailsfiles(list, opts.tempdir)
  end
end

if opts.mbfile
  user = read_user(opts.mbfile)
  conn = mblogin(user)
  list.each { |entry|
    Log.info("Insert into mbdb: #{entry.title}")
    mbinsert(conn, entry, opts.tempdir)
  }
  mblogout(conn)
end

if opts.ttdelete
  user = read_user(opts.ttdelete)
  conn = ttlogin(user)
  ttdelete(conn, list)
  ttlogout(conn)
end


