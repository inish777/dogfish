#!/usr/bin/env ruby

require 'gtk2'
#require 'libglade2'
#require 'gettext'

def _(v)
	v
end


class SearchAgentFind

	def initialize(dogfish)
		@dogfish = dogfish
	end

	def build_gui(box)
		@search_box = box

		t = Gtk::Table.new(3, 2)
		@search_box.pack_start t, false

		l = Gtk::Label.new(_('File name'))
		l.set_alignment(0, 0.5)
		t.attach l, 0, 1, 0, 1, Gtk::SHRINK, Gtk::FILL, 2
		@entry_find_text = Gtk::Entry.new()
		t.attach @entry_find_text, 1, 2, 0, 1

		l = Gtk::Label.new(_('Path'))
		l.set_alignment(0, 0.5)
		t.attach l, 0, 1, 1, 2, Gtk::SHRINK, Gtk::FILL, 2
		@entry_find_path = Gtk::Entry.new()
		t.attach @entry_find_path, 1, 2, 1, 2
		@entry_find_path.text = '/'
	end

	def do_search
		text = @entry_find_text.text
		path = @entry_find_path.text

		f1r, f1 = IO.pipe
		f2r, f2 = IO.pipe

		pid = fork do
			f1r.close
			f2r.close
			exec 'find', path, \
				'(', '-name', "*#{text}*", '-fprintf', "/dev/fd/#{f1.to_i}", '%s %y %p\n', ')', ',', \
				'(', '-type', "d", '-fprint', "/dev/fd/#{f2.to_i}", ')'
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
						lines = buffer1.split("\n")

						if !f1_eof
							buffer1 = lines.pop
						end

						lines.each do |line|
							line = line.strip
							next if line == ''

							#puts "found #{line}"

							size, type, filename = line.split(' ', 3)
							h = Hash[
								'filename' => filename,
								'size' => size,
								'type' => type,
							]
							@dogfish.find_add_result(h)
						end

						if lines.size > 0
							@dogfish.find_update_stat
						end

						throw :done if f1_eof

					elsif f == f2r
						buffer2 += result
						lines = buffer2.split("\n")
						buffer2 = lines.pop
						if lines.size > 0
							line = lines.pop
							#puts "dir #{line}"
							@dogfish.find_set_status(_('Searching in %s') % line)
						end
					end
				end
			end # while

		end # catch

		ensure

		f1r.close
		f2r.close

		Process.kill("KILL", pid)

	end
end

class Dogfish < Gtk::Window

#	include GetText
#	bindtextdomain("dogfish")

	attr_reader :force_exit
	attr_reader :stop_search

	def initialize
		super

		@agent = SearchAgentFind.new(self)

		@found_files = []

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
		column = Gtk::TreeViewColumn.new("Size", renderer, :text => 1)
		column.resizable = true
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
					@selection = iter[0]
					@file_menu.popup(nil, nil, event.button, event.time)
				end
			end
		end

		# Popup the menu on Shift-F10
		@treeview_files.signal_connect("popup_menu") {
			selection = @treeview_files.selection
			if iter = selection.selected
				@selection = iter[0]
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
			["Open containing folder", "thunar \"%d\""],
			["Copy file name", "echo \"%p\" | xclip -selection clipboard"],
		]

		@file_menu = Gtk::Menu.new
		actions.each do |action|
			item = Gtk::MenuItem.new(action[0])
			@file_menu.append(item)
			item.signal_connect("activate") do |widget|
				a = action[1]

				file_path = @selection
				file_dirname = File.dirname(file_path)

				m = false
				a = a.gsub(/%./) do |match|
					case match
						when "%p" then m = true ; file_path
						when "%d" then m = true ; file_dirname
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
		# Stop GTK, since we are done
		@force_exit = true;
		Gtk.main_quit
	end

	def find_update_stat
		@found_label.text =_('%d found') % @found_files.size
		Gtk.main_iteration while Gtk.events_pending?
	end

	def find_add_result(h)
		h['filename'] = h['filename'].force_encoding("UTF-8").
			encode("UTF-16BE", :invalid=>:replace, :replace=>"?").encode("UTF-8")

		row = @listmodel.append

		row[0] = h['filename']

		if h['type'] == 'd'
			row[1] = -1
		else
			row[1] = h['size'].to_i
		end

		h['list_row'] = row

		@found_files << h
	end

	def find_set_status(text)
		@statusbar.push(@statusbar.get_context_id('results'), text)
		Gtk.main_iteration while Gtk.events_pending?
	end

	def find
		@searching = true
		@stop_search = false

		@button_find.label = Gtk::Stock::CANCEL

		@listmodel = Gtk::ListStore.new(String, Integer)
		@treeview_files.model = @listmodel
		@treeview_files.columns_autosize()

		@found_files = []

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


