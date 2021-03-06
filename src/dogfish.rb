#!/usr/bin/env ruby

require 'gtk2'
require 'shellwords'
#require 'libglade2'
#require 'gettext'

def _(v)
	v
end


$xdg_cache_home = ENV['XDG_CACHE_HOME']
$xdg_cache_home = File.join(ENV['HOME'], '.cache') if $xdg_cache_home.nil?

$my_xdg_cache_home = File.join($xdg_cache_home, 'dogfish')


class Dir
	def self.mkdir_p(path)
		return if exist? path
		mkdir_p File.dirname(path)
		mkdir(path)
	end
end

def human_readable_size(size)
	size = size.to_f
	if size > (1024 * 1024)
		'%.2fMiB' %(size / (1024 * 1024))
	elsif size > 1024
		'%.2fKiB' %(size / 1024)
	else
		size.to_i.to_s + 'B'
	end
end

def human_readable_size2(size)
	size.to_s.reverse.scan(/..?.?/).join(' ').reverse
end

class HistoryDispatcher

	def initialize()
		@widgets = Hash.new(Hash.new)
	end

	def get_history_list(agent_id, widget_id, to_append = [])
		path = File.join($my_xdg_cache_home, 'history', agent_id, widget_id)
		return to_append if !File::file?(path) || !File::readable?(path)

		history = []

		begin
			File.open(path) { |f| history = f.read.lines }
		rescue
		end

		history = [*to_append, *history].map {|line| line.sub("\n", '')} .uniq.first(20)

		return history
	end

	def update_combo_box(widget, newitems)
		olditems = widget.model.to_enum.map {|v| v[2][0]}
		newitems = [*newitems, *olditems].uniq.first(20)

		model = Gtk::TreeStore.new(String);
		newitems.each do |item|
			row = model.append(nil)
			row[0] = item
		end
		widget.model = model
	end

	def register_widget(widget, agent_id, widget_id)
		@widgets[agent_id][widget_id] = widget

		history_list = get_history_list(agent_id, widget_id)
		update_combo_box(widget, history_list)
	end

	def save(agent_id, widget_id = nil)

		if widget_id.nil?
			@widgets[agent_id].each_key { |k| save(agent_id, k) if !k.nil? }
			return
		end

		new_item = @widgets[agent_id][widget_id].child().text

		update_combo_box(@widgets[agent_id][widget_id], new_item)

		history = get_history_list(agent_id, widget_id, [new_item])

		path = File.join($my_xdg_cache_home, 'history', agent_id, widget_id)
		Dir.mkdir_p(File.dirname(path))

		# some sanity checks
		if File.exist?(path)
			return if !File.file?(path)   # strange thing happened, give up
			return if !File.owned?(path)  # someone can steal our history?
			File.chmod(0600, path)        # make sure no one can
		end

		File.open(path, "w", 0600) do |file|
			file.puts history.join("\n")
		end
 	end

end

class SearchAgentFind

	def initialize(dogfish, history_dispatcher)
		@dogfish = dogfish
		@history_dispatcher = history_dispatcher
	end

	def build_gui(box)
		@search_box = box

		t = Gtk::Table.new(5, 4)
		@search_box.pack_start t, false

		l = Gtk::Label.new(_('_File name'), true)
		l.set_alignment(0, 0.5)
		t.attach l, 0, 1, 0, 1, Gtk::SHRINK|Gtk::FILL, Gtk::FILL, 2
		l.mnemonic_widget = @entry_find_text = Gtk::ComboBoxEntry.new()
		t.attach @entry_find_text, 1, 4, 0, 1
		@history_dispatcher.register_widget(@entry_find_text, "find", "file_name")

		l = Gtk::Label.new(_('_Path'), true)
		l.set_alignment(0, 0.5)
		t.attach l, 0, 1, 1, 2, Gtk::SHRINK|Gtk::FILL, Gtk::FILL, 2
		l.mnemonic_widget = @entry_find_path = Gtk::ComboBoxEntry.new()
		t.attach @entry_find_path, 1, 4, 1, 2
		@entry_find_path.child().text = "/"
		@history_dispatcher.register_widget(@entry_find_path, "find", "path")

		l = Gtk::Label.new(_('_Size'), true)
		l.set_alignment(0, 0.5)
		t.attach l, 0, 1, 2, 3, Gtk::SHRINK|Gtk::FILL, Gtk::FILL, 2
		l.mnemonic_widget = @entry_find_size = Gtk::ComboBoxEntry.new()
		t.attach @entry_find_size, 1, 2, 2, 3
		@entry_find_size.child().text = "*"
		@history_dispatcher.register_widget(@entry_find_size, "find", "size")

		l = Gtk::Label.new(_('_Type'), true)
		l.set_alignment(0, 0.5)
		t.attach l, 2, 3, 2, 3, Gtk::SHRINK|Gtk::FILL, Gtk::FILL, 2
		l.mnemonic_widget = @entry_find_type = Gtk::ComboBoxEntry.new()
		t.attach @entry_find_type, 3, 4, 2, 3
		@entry_find_type.child().text = "*"
		@history_dispatcher.register_widget(@entry_find_type, "find", "type")

		l = Gtk::Label.new(_('Max _Depth'), true)
		l.set_alignment(0, 0.5)
		t.attach l, 0, 1, 3, 4, Gtk::SHRINK|Gtk::FILL, Gtk::FILL, 2
		l.mnemonic_widget = @entry_find_maxdepth = Gtk::ComboBoxEntry.new()
		t.attach @entry_find_maxdepth, 1, 2, 3, 4
		@entry_find_maxdepth.child().text = "*"
		@history_dispatcher.register_widget(@entry_find_maxdepth, "find", "max_depth")

		l = Gtk::Label.new(_('_Content'), true)
		l.set_alignment(0, 0.5)
		t.attach l, 0, 1, 4, 5, Gtk::SHRINK|Gtk::FILL, Gtk::FILL, 2
		l.mnemonic_widget = @entry_content = Gtk::ComboBoxEntry.new()
		t.attach @entry_content, 1, 4, 4, 5
		@entry_content.child().text = ''
		@history_dispatcher.register_widget(@entry_content, "find", "content")

	end

	def grep(h, pattern)
		filename = h['filename']
		filesize = h['size'].to_f
		bytesscanned = 0;

		#p "Scanning file #{filename}"

		return if !File.readable?(filename)

		@dogfish.find_set_status(_('Scanning %s (%s)') % [filename, human_readable_size(filesize) ] )

		linenr = 1
		File.open(filename) do |file|
			restart = false
			begin
				while !file.eof
					line = file.gets
					bytesscanned += line.size
					if line[pattern]
						h1 = h.clone
						h1['line'] = linenr
						h1['content'] = line.gsub(/[\n\r]*/, '')
						@dogfish.find_add_result(h1)
					end
					linenr += 1
					if linenr % 800 == 0
						@dogfish.find_set_status(
							('Scanning %s (%s of %s)') % [filename,
								human_readable_size(bytesscanned),
								human_readable_size(filesize) ] )
						return if @dogfish.update_gui
					end
				end
			rescue ArgumentError => e
				restart = true
			end

			if restart
				while !file.eof
					line = file.gets
					bytesscanned += line.size
					line = line.
						force_encoding("UTF-8").encode("UTF-16BE", :invalid=>:replace, :replace=>"?").encode("UTF-8")
					if line[pattern]
						h1 = h.clone
						h1['line'] = linenr
						h1['content'] = line.gsub(/[\n\r]*/, '')
						@dogfish.find_add_result(h1)
					end
					linenr += 1
					if linenr % 400 == 0
						@dogfish.find_set_status(
							('Scanning %s (%s of %s)') % [filename,
								human_readable_size(bytesscanned),
								human_readable_size(filesize) ] )
						return if @dogfish.update_gui
					end
				end
			end # restart
		end # open
	end

	def do_search
		text = @entry_find_text.child().text	
		path = @entry_find_path.child().text
		size = @entry_find_size.child().text
		type = @entry_find_type.child().text
		maxdepth = @entry_find_maxdepth.child().text
		content = @entry_content.child().text

		pattern = Regexp.new(content)

		@history_dispatcher.save('find')

		f1r, f1 = IO.pipe
		f2r, f2 = IO.pipe

		pid = fork do
			f1r.close
			f2r.close

			text = "*#{text}*"if !text[/[*?\[\]]/] && text != ''
			p_text = []
			p_text = ['-name', text] if text != ''

			p_size = []
			if size != '' && size != '*'
				size = size + 'c' if size[size.size-1][/[0-9]/]
				p_size = ['-size', size]
			end

			p_type = []
			type = '' if type[/[*]/]
			type = 'fl' if !content.empty?
			type.scan(/[bcdpflsD]/) do |m|
				p_type << '-o' if p_type.size > 0
				p_type << '-type'
				p_type << m
			end
			p_type = ['(', *p_type, ')'] if p_type.size > 0

			p_maxdepth = []
			maxdepth = maxdepth.strip
			if maxdepth != '' && maxdepth != '*'
				maxdepth = maxdepth.to_i
				p_maxdepth = ['-maxdepth', maxdepth.to_s] if maxdepth >= 0
			end

			p_all = [*p_text, *p_type, *p_size]
			p_all = ['-true'] if p_all.empty?

			program = 'find'
			find_is_known_to_be_patched = false;

			#program = '/media/work/home/vadim/builds/findutils/bin/find'
			#find_is_known_to_be_patched = true;

			f2 = f1 if (find_is_known_to_be_patched)

			command = [program, path, *p_maxdepth, \
				'(', *p_all, '-fprintf', "/dev/fd/#{f1.to_i}", 'found %s %y %p\n', ')', ',', \
				'(', '-type', "d", '-fprintf', "/dev/fd/#{f2.to_i}", 'dir _ _ %p\n', ')']

			exec *command
			exit!
		end

		f1.close
		f2.close

		buffer1 = ''
		buffer2 = ''

		f1_eof = false

		fds = [f1r, f2r]

		catch (:done) do
			while 1
				if @dogfish.force_exit
					Gtk.main_quit
					return
				end

				throw :done if @dogfish.stop_search

				rs, ws = IO.select(fds)
				rs.each do |f|
					begin
						result = f.read_nonblock(1024)
					rescue EOFError => e
						result = ''
						if f == f1r
							f1_eof = true
						else
							fds = [f1r]
						end
					end
					if f == f1r
						buffer1 += result

						#lines = buffer1.split("\n")
						#String.split removes trailing whitespaces so we have to use String.scan
						lines = buffer1.scan(/([^\n]+(\n|$))/).map{|v1, v2| v1}

						#puts lines
						#puts '-----'

						if !f1_eof
							buffer1 = lines.pop
						end

						dir = ''

						lines.each do |line|
							line = line.strip
							next if line == ''

							#puts "found #{line}"

							source, size, type, filename = line.split(' ', 4)
							if source == 'dir'
								dir = filename
							else
								h = Hash[
									'filename' => filename,
									'size' => size,
									'type' => type,
								]
								if !content.empty?
									grep(h, pattern)
								else
									@dogfish.find_add_result(h)
								end
							end
						end

						if lines.size > 0
							@dogfish.find_update_stat
						end

						@dogfish.find_set_status(_('Searching in %s') % dir) if !dir.empty?

						throw :done if f1_eof

					elsif f == f2r
						buffer2 += result
						lines = buffer2.split("\n")
						buffer2 = lines.pop
						if lines.size > 0
							line = lines.pop
							dir = line.split(' ', 4)[3]
							#puts "dir #{line}"
							@dogfish.find_set_status(_('Searching in %s') % dir)
						end
					end
				end
			end # while

		end # catch

		ensure

		f1r.close if !f1r.nil?
		f2r.close if !f2r.nil?

		Process.kill("KILL", pid) if !pid.nil?

	end

end

class Dogfish < Gtk::Window

#	include GetText
#	bindtextdomain("dogfish")

	attr_reader :force_exit
	attr_reader :stop_search

	def initialize
		super
		@history_dispatcher = HistoryDispatcher.new
		@agent = SearchAgentFind.new(self, @history_dispatcher)

		@found_files = []
		@found_files_by_path = Hash[]

		@window = Gtk::Window.new
		@window_box = Gtk::VBox.new()
		@window.add @window_box

		@window.title = "dogfish"
		@window.default_width = 750
		@window.default_height = 500

		# Search box

		@search_box = Gtk::HBox.new()
		@window_box.pack_start @search_box, false

		agent_gui_box = Gtk::VBox.new()
		@search_box.pack_start agent_gui_box, true

		@agent.build_gui(agent_gui_box)

		@button_find = Gtk::Button.new(Gtk::Stock::FIND)
		@search_box.pack_start @button_find, false

		# Treeview

		@scrolled_files = Gtk::ScrolledWindow.new
		@window_box.pack_start @scrolled_files

		@treeview_files = Gtk::TreeView.new
		@scrolled_files.add @treeview_files

		renderer = Gtk::CellRendererText.new
		column = Gtk::TreeViewColumn.new("Filename", renderer, :text => 0)
		column.resizable = true
		column.expand = true
		@treeview_files.append_column(column)

		renderer = Gtk::CellRendererText.new
		renderer.xalign = 1
		column = Gtk::TreeViewColumn.new("Size", renderer, :text => 1, :visible => 2)
		column.resizable = true
		column.alignment = 1
		@treeview_files.append_column(column)

		# Statusbar

		@statusbar = Gtk::Statusbar.new()
		@window_box.pack_start @statusbar, false

		@found_label = Gtk::Label.new("")
		@statusbar.add @found_label


		@window.signal_connect('destroy'){self.on_button_close_clicked}
		@button_find.signal_connect('clicked'){self.on_button_find_clicked}

		initialize_file_menu

		@treeview_files.signal_connect("button_press_event") do |widget, event|
			if event.kind_of? Gdk::EventButton and event.button == 3
				selection = @treeview_files.selection
				if iter = selection.selected
					@selection = iter
					@file_menu.popup(nil, nil, event.button, event.time)
				end
			end
		end

		# Popup the menu on Shift-F10
		@treeview_files.signal_connect("popup_menu") {
			selection = @treeview_files.selection
			if iter = selection.selected
				@selection = iter
				@file_menu.popup(nil, nil, 0, Gdk::Event::CURRENT_TIME)
			end
		}


		@force_exit = false
		@stop_search = false
		@searching = false


		@window.show_all

		# Start GTK processing
		Gtk.main()
	end


	def initialize_file_menu
		actions = [
			["Open", "xdg-open"],
			["Open in medit", "medit -l %l %p"],
			["Open in adie", "adie -l %l %p"],
			["Open containing folder", "thunar \"%d\""],
			["Copy file name", "echo \"%p\" | xclip -selection clipboard"],
		]

		@file_menu = Gtk::Menu.new
		actions.each do |action|
			item = Gtk::MenuItem.new(action[0])
			@file_menu.append(item)
			item.signal_connect("activate") do |widget|
				a = action[1]

				file_path = @selection[3]
				file_line = @selection[4]
				file_dirname = File.dirname(file_path)

				m = false
				a = a.gsub(/%./) do |match|
					case match
						when "%l" then file_line.to_s
						when "%p" then m = true ; file_path.shellescape
						when "%d" then m = true ; file_dirname.shellescape
						else match
					end
				end
				a = "#{a} \"#{file_path}\"" if !m;
				pid = fork { system(a) }
				Process.detach(pid)
			end
		end
		@file_menu.show_all
	end

	def on_button_close_clicked
		@force_exit = true;
		Gtk.main_quit
	end

	def find_update_stat
		@found_label.text =_('%d found') % @found_files.size
		Gtk.main_iteration while Gtk.events_pending?
	end

	def update_gui
		Gtk.main_iteration while Gtk.events_pending?
		@force_exit || @stop_search
	end

	def find_add_result(h)
		h['filename'] = h['filename'].force_encoding("UTF-8").
			encode("UTF-16BE", :invalid=>:replace, :replace=>"?").encode("UTF-8")

		if !@found_files_by_path.has_key?(h['filename'])

			row = @listmodel.append(nil)
			row[0] = h['filename']

			if h['type'] == 'd'
				row[1] = _('Directory')
			else
				row[1] = human_readable_size2(h['size'])
			end
			row[2] = 1
			row[3] = h['filename']
			row[4] = 0

			h['list_row'] = row

			@found_files << h
			@found_files_by_path[h['filename']] = h
		end

		if h.has_key?('content') || h.has_key?('line')
			row = @found_files_by_path[h['filename']]['list_row']

			subrow = @listmodel.append(row)
			subrow[0] = h['line'].to_s + ': ' + h['content'].to_s
			subrow[2] = 0
			subrow[3] = h['filename']
			subrow[4] = h['line'].to_i
		end
	end

	def find_set_status(text)
		@statusbar.push(@statusbar.get_context_id('results'), text)
		Gtk.main_iteration while Gtk.events_pending?
	end

	def find
		@searching = true
		@stop_search = false

		@button_find.label = Gtk::Stock::CANCEL

		@listmodel = Gtk::TreeStore.new(String, String, Integer, String, Integer)
		@treeview_files.model = @listmodel
		@treeview_files.columns_autosize()

		@found_files = []
		@found_files_by_path = Hash[]

		find_update_stat

		@agent.do_search

		ensure

		find_update_stat

		if @stop_search
			find_set_status _('Canceled')
		else
			find_set_status _('Ready')
		end

		@button_find.label = Gtk::Stock::FIND

		@searching = false

	end

	def on_button_find_clicked

		if @searching
			@stop_search = true
		else
			find
		end

	end

end

Dogfish.new
