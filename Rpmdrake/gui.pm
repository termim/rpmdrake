package Rpmdrake::gui;
#*****************************************************************************
#
#  Copyright (c) 2002 Guillaume Cottenceau
#  Copyright (c) 2002-2007 Thierry Vignaud <tvignaud@mandriva.com>
#  Copyright (c) 2003, 2004, 2005 MandrakeSoft SA
#  Copyright (c) 2005-2007 Mandriva SA
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License version 2, as
#  published by the Free Software Foundation.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
#
#*****************************************************************************
#
# $Id$

use strict;
our @ISA = qw(Exporter);
use lib qw(/usr/lib/libDrakX);

use common;
use mygtk3 qw(gtknew); #- do not import gtkadd which conflicts with ugtk3 version

use ugtk3 qw(:helpers :wrappers);
use rpmdrake;
use Rpmdrake::open_db;
use Rpmdrake::formatting;
use Rpmdrake::init;
use Rpmdrake::pkg;
use Rpmdrake::icon;
use feature 'state';
#use warnings;
#use strict;

our @EXPORT = qw(
                    $descriptions
                    $find_entry
                    $force_displaying_group
                    $force_rebuild
                    $pkgs
                    $results_ok
                    $results_none
                    $size_free
                    $size_selected
                    $urpm
                    %grp_columns
                    %pkg_columns
                    @filtered_pkgs
                    @initial_selection
                    ask_browse_tree_given_widgets_for_rpmdrake
                    build_tree
                    callback_choices
                    compute_main_window_size
                    do_action
                    get_info
                    get_summary
                    is_locale_available
                    node_state
                    pkgs_provider
                    real_quit
                    reset_search
                    set_node_state
                    sort_callback
                    switch_pkg_list_mode
                    toggle_all
                    toggle_nodes
            );

our ($descriptions, %filters, @filtered_pkgs, %filter_methods, $force_displaying_group, $force_rebuild, @initial_selection, $pkgs, $size_free, $size_selected, $urpm);
our ($results_ok, $results_none) = (N("Search results"), N("Search results (none)"));

our %grp_columns = (
    label => 0,
    icon => 2,
);

our %pkg_columns = (
    text => 0,
    state_icon => 1,
    state => 2,
    selected => 3,
    short_name => 4,
    version => 5,
    release => 6,
    'arch' => 7,
    selectable => 8,
);


sub compute_main_window_size {
    my ($w) = @_;
    ($typical_width) = string_size($w->{real_window}, translate("Graphical Environment") . "xmms-more-vis-plugins");
    $typical_width > 600 and $typical_width = 600;  #- try to not being crazy with a too large value
    $typical_width < 150 and $typical_width = 150;
}

sub get_summary {
    my ($key) = @_;
    my $summary = translate($pkgs->{$key}{pkg}->summary);
    require utf8;
    utf8::valid($summary) ? $summary : @{[]};
}

sub build_expander {
    my ($pkg, $label, $type, $get_data, $o_installed_version) = @_;
    my $textview;
    gtkadd(
        gtkshow(my $exp = gtksignal_connect(
            Gtk3::Expander->new(format_field($label)),
            activate => sub {
                state $first;
                return if $first;
                $first = 1;
                slow_func($::main_window->get_window, sub {
                              extract_header($pkg, $urpm, $type, $o_installed_version);
                              gtktext_insert($textview, $get_data->() || [ [  N("(Not available)") ] ]);
                          });
            })),
        $textview = gtknew('TextView')
    );
    $exp->set_use_markup(1);
    $exp;
}


sub get_advisory_link {
    my ($update_descr) = @_;
    my $link = gtkshow(Gtk3::LinkButton->new($update_descr->{URL}, N("Security advisory")));
    [ $link ];
}

sub get_description {
    my ($pkg, $update_descr) = @_;
    @{ ugtk3::markup_to_TextView_format(join("\n",
                                             (eval {
                                                 escape_text_for_TextView_markup_format(
                                                     $pkg->{description}
                                                       || $update_descr->{description});
                                             } || '<i>' . N("No description") . '</i>')
                                         )) };
}

sub get_string_from_keywords {
    my ($medium, $name) = @_;
    my @media_types;
    if ($medium->{mediacfg}) {
        my ($distribconf, $medium_path) = @{$medium->{mediacfg}};
        @media_types = split(':', $distribconf->getvalue($medium_path, 'media_type')) if $distribconf;
    }

    my $unsupported = N("It is <b>not supported</b> by OpenMandriva.");
    my $dangerous = N("It may <b>break</b> your system.");
    my $s;
    $s .= N("This package is not free software") . "\n" if member('non-free', @media_types);
    if ($pkgs->{$name}{is_backport} || member('backport', @media_types)) {
        return join("\n",
                    N("This package contains a new version that was backported."),
                    $unsupported, $dangerous, $s);
    } elsif (member('testing', @media_types)) {
        return join("\n",
                    N("This package is a potential candidate for an update."),
                    $unsupported, $dangerous, $s);
    } elsif (member('updates', @media_types)) {
        return join("\n",
                    (member('official', @media_types) ?
                       N("This is an official update which is supported by OpenMandriva.")
                       : (N("This is an unofficial update."), $unsupported))
                    ,
                    $s);
    } else {
        $s .= N("This is an official package supported by OpenMandriva") . "\n" if member('official', @media_types);
        return $s;
    }
}

sub get_main_text {
    my ($medium, $fullname, $name, $summary, $is_update, $update_descr) = @_;

    my $txt = get_string_from_keywords($medium, $fullname);
 
    ugtk3::markup_to_TextView_format(
        # force align "name - summary" to the right with RTL languages (#33603):
        if_(mygtk3::text_direction_rtl(), "\x{200f}") .
          join("\n",
               format_header(join(' - ', $name, $summary)) .
                 # workaround gtk+ bug where GtkTextView wronly limit embedded widget size to bigger line's width (#25533):
                 "\x{200b} \x{feff}" . ' ' x 120,
               if_($txt, format_field(N("Notice: ")) . $txt),
               if_($is_update, # is it an update?
                   format_field(N("Importance: ")) . format_update_field($update_descr->{importance}),
                   format_field(N("Reason for update: ")) . format_update_field(rpm_description($update_descr->{pre})),
               ),
               ''  # extra empty line
           ));
}

sub get_details {
    my ($pkg, $upkg, $installed_version, $raw_medium) = @_;
    my $a = ugtk3::markup_to_TextView_format(
        $spacing . join("\n$spacing",
                        eval { format_field(N("Version: ")) . $upkg->EVR },
                        ($upkg->flag_installed ?
                           format_field(N("Currently installed version: ")) . $installed_version : ()
                        ),
                        format_field(N("Group: ")) . translate_group($upkg->group),
                        format_field(N("Architecture: ")) . $upkg->arch,
                        format_field(N("Size: ")) . N("%s KB", int($upkg->size/1024)),
                        eval { format_field(N("Medium: ")) . $raw_medium->{name} },
                    ),
    );
    my @link = get_url_link($upkg, $pkg);
    push @$a, @link if @link;
    $a;
}

sub get_new_deps {
    my ($urpm, $upkg) = @_;
    my $deps_textview;
    my @a = [ gtkadd(
        gtksignal_connect(
            gtkshow(my $dependencies = Gtk3::Expander->new(format_field(N("New dependencies:")))), 
            activate => sub { 
                slow_func($::main_window->get_window, sub {
                              my $state = {};
                              my $db = open_rpm_db();
                              my @requested = $urpm->resolve_requested__no_suggests_(
                                  $db, $state,
                                  { $upkg->id => 1 },
                              );
                              @requested = $urpm->resolve_requested_suggests($db, $state, \@requested);
                              undef $db;
                              my @nodes_with_deps = map { urpm_name($_) } @requested;
                              my @deps = sort { $a cmp $b } difference2(\@nodes_with_deps, [ urpm_name($upkg) ]);
                              @deps = N("All dependencies installed.") if !@deps;
                              gtktext_insert($deps_textview, join("\n", @deps));
                          });
            }
        ),
        $deps_textview = gtknew('TextView')
    ) ];
    $dependencies->set_use_markup(1);
    @a;
}

sub get_url_link {
    my ($upkg, $pkg) = @_;

    my $url = $upkg->url || $pkg->{url};

    if (!$url) {
        open_rpm_db()->traverse_tag_find('name', $upkg->name, sub { $url = $_[0]->url });
    }

    return if !$url;

    my @a =
      (@{ ugtk3::markup_to_TextView_format(format_field("\n$spacing" . N("URL: "))) },
        [ my $link = gtkshow(Gtk3::LinkButton->new($url, $url)) ]);
    @a;
}

sub files_format {
    my ($files) = @_;
    ugtk3::markup_to_TextView_format(
        '<tt>' . $spacing #- to highlight information
          . join("\n$spacing", map { "\x{200e}$_" } @$files)
            . '</tt>');
}

sub format_pkg_simplifiedinfo {
    my ($pkgs, $key, $urpm, $descriptions) = @_;
    my ($name) = split_fullname($key);
    my $pkg = $pkgs->{$key};
    my $upkg = $pkg->{pkg};
    return if !$upkg;
    my $raw_medium = pkg2medium($upkg, $urpm);
    my $medium = !$raw_medium->{fake} ? $raw_medium->{name} : undef;
    my $update_descr = $descriptions->{$medium}{$name};
    # discard update fields if not matching:
    my $is_update = ($upkg->flag_upgrade && $update_descr && $update_descr->{pre});
    my $summary = get_summary($key);
    my $s = get_main_text($raw_medium, $key, $name, $summary, $is_update, $update_descr);
    push @$s, get_advisory_link($update_descr) if $is_update;

    push @$s, get_description($pkg, $update_descr);
    push @$s, [ "\n" ];
    my $installed_version = eval { find_installed_version($upkg) };

    push @$s, [ gtkadd(gtkshow(my $details_exp = Gtk3::Expander->new(format_field(N("Details:")))),
                       gtknew('TextView', text => get_details($pkg, $upkg, $installed_version, $raw_medium))) ];
    $details_exp->set_use_markup(1);
    push @$s, [ "\n\n" ];
    push @$s, [ build_expander($pkg, N("Files:"), 'files', sub { files_format($pkg->{files}) }) ];
    push @$s, [ "\n\n" ];
    push @$s, [ build_expander($pkg, N("Changelog:"), 'changelog',  sub { $pkg->{changelog} }, $installed_version) ];

    push @$s, [ "\n\n" ];
    if ($upkg->id) { # If not installed
        push @$s, get_new_deps($urpm, $upkg);
    }
    $s;
}

sub format_pkg_info {
    my ($pkgs, $key, $urpm, $descriptions) = @_;
    my $pkg = $pkgs->{$key};
    my $upkg = $pkg->{pkg};
    my ($name, $version) = split_fullname($key);
    my @files = (
	format_field(N("Files:\n")),
	exists $pkg->{files}
	    ? '<tt>' . join("\n", map { "\x{200e}$_" } @{$pkg->{files}}) . '</tt>' #- to highlight information
	    : N("(Not available)"),
    );
    my @chglo = (format_field(N("Changelog:\n")), ($pkg->{changelog} ? @{$pkg->{changelog}} : N("(Not available)")));
    my @source_info = (
	$MODE eq 'remove' || !@$max_info_in_descr
	    ? ()
	    : (
		format_field(N("Medium: ")) . pkg2medium($upkg, $urpm)->{name},
		format_field(N("Currently installed version: ")) . find_installed_version($upkg),
	    )
    );
    my @max_info = @$max_info_in_descr && $changelog_first ? (@chglo, @files) : (@files, '', @chglo);
    ugtk3::markup_to_TextView_format(join("\n", format_field(N("Name: ")) . $name,
      format_field(N("Version: ")) . $version,
      format_field(N("Architecture: ")) . $upkg->arch,
      format_field(N("Size: ")) . N("%s KB", int($upkg->size/1024)),
      if_(
	  $MODE eq 'update',
	  format_field(N("Importance: ")) . $descriptions->{$name}{importance}
      ),
      @source_info,
      '', # extra empty line
      format_field(N("Summary: ")) . $upkg->summary,
      '', # extra empty line
      if_(
	  $MODE eq 'update',
	  format_field(N("Reason for update: ")) . rpm_description($descriptions->{$name}{pre}),
      ),
      format_field(N("Description: ")), ($pkg->{description} || $descriptions->{$name}{description} || N("No description")),
      @max_info,
    ));
}

sub warn_if_no_pkg {
    my ($name) = @_;
    my ($short_name) = split_fullname($name);
    state $warned;
    if (!$warned) {
        $warned = 1;
        interactive_msg(N("Warning"),
                        join("\n",
                             N("The package \"%s\" was found.", $name),
                             N("However this package is not in the package list."),
                             N("You may want to update your urpmi database."),
                             '',
                             N("Matching packages:"),
                             '',
                             join("\n", sort map {
                                 ref($pkgs->{$_}) ?
				     #-PO: this is list fomatting: "- <package_name> (medium: <medium_name>)"
				     #-PO: eg: "- rpmdrake (medium: "Main Release"
				     N("- %s (medium: %s)", $_, pkg2medium($pkgs->{$_}{pkg}, $urpm)->{name})
				     : N("- %s", $_);
                             } grep { /^$short_name/ } keys %$pkgs),

                         ),
                        scroll => 1,
                    );
    }
    return 'XXX';
}

sub node_state {
    my ($name) = @_;
    #- checks $_[0] -> hack for partial tree displaying
    return 'XXX' if !$name;
    my $pkg = $pkgs->{$name};
    my $urpm_obj = $pkg->{pkg};
    if (!$urpm_obj) {
       my $res = eval { warn_if_no_pkg($name) };
       if (my $err = $@) {
	       warn "ERROR: $err\n";
	       log::explanations("ERROR: $err");
       }
       return $res;
    }
    $pkg->{selected} ?
      ($urpm_obj->flag_installed ?
         ($urpm_obj->flag_upgrade ? 'to_install' : 'to_remove')
           : 'to_install')
        : ($urpm_obj->flag_installed ? 
            ($pkgs->{$name}{is_backport} ? 'backport' :
             ($urpm_obj->flag_upgrade ? 'to_update'
                : ($urpm_obj->flag_base ? 'base' : 'installed')))
               : 'uninstalled');
}

my ($common, $w, %wtree, %ptree, %pix);

sub set_node_state {
    my ($iter, $state, $model) = @_;
    return if $state eq 'XXX' || !$state;
    $pix{$state} ||= gtkcreate_pixbuf('state_' . $state);
    $model->set($iter, $pkg_columns{state_icon} => $pix{$state});
    $model->set($iter, $pkg_columns{state} => $state);
    $model->set($iter, $pkg_columns{selected} => to_bool(member($state, qw(base installed to_install)))); #$pkg->{selected}));
    $model->set($iter, $pkg_columns{selectable} => to_bool($state ne 'base'));
}

sub set_leaf_state {
    my ($leaf, $state, $model) = @_;
    set_node_state($_, $state, $model) foreach @{$ptree{$leaf}};
}

sub grep_unselected { grep { exists $pkgs->{$_} && !$pkgs->{$_}{selected} } @_ }

sub add_parent {
    my ($root, $state) = @_;
    $root or return undef;
    if (my $w = $wtree{$root}) { return $w }
    my $s; foreach (split '\|', $root) {
        my $s2 = $s ? "$s|$_" : $_;
        $wtree{$s2} ||= do {
            my $pixbuf;
	    $pixbuf = get_icon($s2, $s) if $show_group_icons->[0];
            my $iter = $w->{tree_model}->append_set($s ? add_parent($s, $state) : undef,
                                                    [ $grp_columns{label} => $_, if_($pixbuf, $grp_columns{icon} => $pixbuf) ]);
            $iter;
        };
        $s = $s2;
    }
    set_node_state($wtree{$s}, $state, $w->{tree_model}); #- use this state by default as tree is building. #
    $wtree{$s};
}

sub add_node {
    my ($leaf, $root, $o_options) = @_;
    my $state = node_state($leaf) or return;
    if ($leaf) {
        my $iter;
        if (is_a_package($leaf)) {
            my ($name, $version, $release, $arch) = split_fullname($leaf);
            $iter = $w->{detail_list_model}->append_set([ $pkg_columns{text} => $leaf,
                                                          $pkg_columns{short_name} => format_name_n_summary($name, get_summary($leaf)),
                                                          $pkg_columns{version} => $version,
                                                          $pkg_columns{release} => $release,
                                                          $pkg_columns{arch} => $arch,
                                                      ]);
            set_node_state($iter, $state, $w->{detail_list_model});
             $ptree{$leaf} = [ $iter ];
        } else {
            $iter = $w->{tree_model}->append_set(add_parent($root, $state), [ $grp_columns{label} => $leaf ]);
            push @{$wtree{$leaf}}, $iter;
        }
    } else {
        my $parent = add_parent($root, $state);
        #- hackery for partial displaying of trees, used in rpmdrake:
        #- if leaf is void, we may create the parent and one child (to have the [+] in front of the parent in the ctree)
        #- though we use '' as the label of the child; then rpmdrake will connect on tree_expand, and whenever
        #- the first child has '' as the label, it will remove the child and add all the "right" children
        $o_options->{nochild} or $w->{tree_model}->append_set($parent, [ $grp_columns{label} => '' ]); # test $leaf?
    }
}

my ($prev_label);
sub update_size {
    my ($common) = shift @_;
    if ($w->{status}) {
        my $new_label = $common->{get_status}();
        $prev_label ne $new_label and $w->{status}->set($prev_label = $new_label);
    }
}

sub children {
    my ($w) = @_;
    map { $w->{detail_list_model}->get($_, $pkg_columns{text}) } gtktreeview_children($w->{detail_list_model});
}

sub toggle_all {
    my ($common, $_val) = @_;
    my $w = $common->{widgets};
    my @l = children($w) or return;

    my @unsel = grep_unselected(@l);
    my @p = @unsel ?
      #- not all is selected, select all if no option to potentially override
      (exists $common->{partialsel_unsel} && $common->{partialsel_unsel}->(\@unsel, \@l) ? difference2(\@l, \@unsel) : @unsel)
        : @l;
    toggle_nodes($w->{detail_list}->get_window, $w->{detail_list_model}, \&set_leaf_state, node_state($p[0]), @p);
    update_size($common);
}

# ask_browse_tree_given_widgets_for_rpmdrake will run gtk+ loop. its main parameter "common" is a hash containing:
# - a "widgets" subhash which holds:
#   o a "w" reference on a ugtk3 object
#   o "tree" & "info" references a TreeView
#   o "info" is a TextView
#   o "tree_model" is the associated model of "tree"
#   o "status" references a Label
# - some methods: get_info, node_state, build_tree, partialsel_unsel, grep_unselected, rebuild_tree, toggle_nodes, get_status
# - "tree_submode": the default mode (by group, ...), ...
# - "state": a hash of misc flags: => { flat => '0' },
#   o "flat": is the tree flat or not
# - "tree_mode": mode of the tree ("gui_pkgs", "by_group", ...) (mainly used by rpmdrake)
          
sub ask_browse_tree_given_widgets_for_rpmdrake {
    ($common) = @_;
    $w = $common->{widgets};

    $w->{detail_list} ||= $w->{tree};
    $w->{detail_list_model} ||= $w->{tree_model};

    $common->{add_parent} = \&add_parent;
    my $clear_all_caches = sub {
	%ptree = %wtree = ();
    };
    $common->{clear_all_caches} = $clear_all_caches;
    $common->{delete_all} = sub {
	$clear_all_caches->();
	$w->{detail_list_model}->clear;
	$w->{tree_model}->clear;
    };
    $common->{rebuild_tree} = sub {
	$common->{delete_all}->();
	$common->{build_tree}($common->{state}{flat}, $common->{tree_mode});
	update_size($common);
    };
    $common->{delete_category} = sub {
	my ($cat) = @_;
	exists $wtree{$cat} or return;
	%ptree = ();

	if (exists $wtree{$cat}) {
	    my $_iter_str = $w->{tree_model}->get_path_str($wtree{$cat});
	    $w->{tree_model}->remove($wtree{$cat});
	    delete $wtree{$cat};
	}
	update_size($common);
    };
    $common->{add_nodes} = sub {
	my (@nodes) = @_;
	$w->{detail_list}->freeze_child_notify;
	my $model = $w->{detail_list}->get_model;
	$w->{detail_list}->set_model;
	$w->{detail_list_model}->clear;
	$w->{detail_list}->scroll_to_point(0, 0);
	add_node($_->[0], $_->[1], $_->[2]) foreach @nodes;
	update_size($common);
	$w->{detail_list}->set_model($model);
	$w->{detail_list}->thaw_child_notify;
    };
    
    $common->{display_info} = sub {
        gtktext_insert($w->{info}, get_info($_[0], $w->{tree}->get_window));
        $w->{info}->scroll_to_iter($w->{info}->get_buffer->get_start_iter, 0, 0, 0, 0);
        0;
    };

    my $fast_toggle = sub {
        my ($iter) = @_;
        gtkset_mousecursor_wait($w->{w}{rwindow}->get_window);
        my $_cleaner = before_leaving { gtkset_mousecursor_normal($w->{w}{rwindow}->get_window) };
        my $name = $w->{detail_list_model}->get($iter, $pkg_columns{text});
        my $urpm_obj = $pkgs->{$name}{pkg};

        if ($urpm_obj->flag_base) {
            interactive_msg(N("Warning"),
                            N("Removing package %s would break your system", $name));
            return '';
        }

        if ($urpm_obj->flag_skip) {
            interactive_msg(N("Warning"), N("The \"%s\" package is in urpmi skip list.\nDo you want to select it anyway?", $name), yesno => 1) or return '';
            $urpm_obj->set_flag_skip(0);
        }

        if ($Rpmdrake::pkg::need_restart && !$priority_up_alread_warned) {
            $priority_up_alread_warned = 1;
            interactive_msg(N("Warning"), '<b>' . N("Rpmdrake or one of its priority dependencies needs to be updated first. Rpmdrake will then restart.") . '</b>' . "\n\n");
        }

        toggle_nodes($w->{tree}->get_window, $w->{detail_list_model}, \&set_leaf_state, $w->{detail_list_model}->get($iter, $pkg_columns{state}),
                     $w->{detail_list_model}->get($iter, $pkg_columns{text}));
	    update_size($common);
    };
    $w->{detail_list}->get_selection->signal_connect(changed => sub {
	my ($model, $iter) = $_[0]->get_selected;
	$model && $iter or return;
     $common->{display_info}($model->get($iter, $pkg_columns{text}));
 });
    ($w->{detail_list}->get_column(0)->get_cells)[0]->signal_connect(toggled => sub {
	    my ($_cell, $path) = @_; #text_
	    my $iter = $w->{detail_list_model}->get_iter_from_string($path);
	    $fast_toggle->($iter) if $iter;
     1;
    });
    $common->{rebuild_tree}->();
    update_size($common);
    $common->{initial_selection} and toggle_nodes($w->{tree}->get_window, $w->{detail_list_model}, \&set_leaf_state, undef, @{$common->{initial_selection}});
    #my $_b = before_leaving { $clear_all_caches->() };
    $common->{init_callback}->() if $common->{init_callback};
    $w->{w}->main;
}

our $find_entry;

sub reset_search() {
    return if !$common;
    $common->{delete_category}->($_) foreach $results_ok, $results_none;
    # clear package list:
    $common->{add_nodes}->();
}

sub is_a_package {
    my ($pkg) = @_;
    return exists $pkgs->{$pkg};
}

sub switch_pkg_list_mode {
    my ($mode) = @_;
    return if !$mode;
    return if !$filter_methods{$mode};
    $force_displaying_group = 1;
    $filter_methods{$mode}->();
}

sub is_updatable {
    my $p = $pkgs->{$_[0]};
    $p->{pkg} && !$p->{selected} && $p->{pkg}->flag_installed && $p->{pkg}->flag_upgrade;
}

sub pkgs_provider {
    my ($mode, %options) = @_;
    return if !$mode;
    my $h = &get_pkgs(%options);
    ($urpm, $descriptions) = @$h{qw(urpm update_descr)};
    $pkgs = $h->{all_pkgs};
    %filters = (
        non_installed => $h->{installable},
        installed => $h->{installed},
        all => [ keys %$pkgs ],
    );
    my %tmp_filter_methods = (
        all => sub { 
            [ difference2([ keys %$pkgs ], $h->{inactive_backports}) ];
        },
        all_updates => sub {
            # potential "updates" from media not tagged as updates:
            if (!$options{pure_updates} && !$Rpmdrake::pkg::need_restart) {
                [ difference2($h->{updates}, $h->{inactive_backports}),
                  difference2([ grep { is_updatable($_) } @{$h->{installable}} ], $h->{backports}) ];
            } else {
                [ difference2($h->{updates}, $h->{inactive_backports}) ];
            }
        },
        backports => sub { $h->{backports} },
        meta_pkgs => sub { 
            [ difference2($h->{meta_pkgs}, $h->{inactive_backports}) ];
        },
        gui_pkgs => sub { 
            [ difference2($h->{gui_pkgs}, $h->{inactive_backports}) ];
        },
    );
    my $tmp_updates = [ difference2($h->{updates}, $h->{inactive_backports}) ];
    foreach my $importance (qw(bugfix security normal)) {
        $tmp_filter_methods{$importance} = sub {
            my @media = keys %$descriptions;
            [ grep { 
                my ($name) = split_fullname($_);
                my $medium = find { $descriptions->{$_}{$name} } @media;
                $medium && $descriptions->{$medium}{$name}{importance} eq $importance } @{$tmp_updates} ];
        };
    }

    undef %filter_methods;
    foreach my $type (keys %tmp_filter_methods) {
        $filter_methods{$type} = sub {
            $force_rebuild = 1; # force rebuilding tree since we changed filter (FIXME: switch to SortModel)
            @filtered_pkgs = intersection($filters{$filter->[0]}, $tmp_filter_methods{$type}->());
        };
    }

    switch_pkg_list_mode($mode);
}

sub closure_removal {
    local $urpm->{state} = {};
    local $urpm->{options}{'force-req-update'} = 0;
    urpm::select::find_packages_to_remove($urpm, $urpm->{state}, \@_);
}

sub is_locale_available {
    my ($name) = @_;
    any { $urpm->{depslist}[$_]->flag_selected } keys %{$urpm->{provides}{$name} || {}} and return 1;
    my $found;
    open_rpm_db()->traverse_tag_find('name', $name, sub { $found = 1 });
    return $found;
}

sub callback_choices {
    my (undef, undef, undef, $choices) = @_;
    return $choices->[0] if $::rpmdrake_options{auto};
    my $callback = sub { interactive_msg(N("More information on package..."), get_info($_[0]), scroll => 1) };
    $choices = [ sort { $a->name cmp $b->name } @$choices ];
    my @choices = interactive_list_(N("Please choose"), (scalar(@$choices) == 1 ? 
    N("The following package is needed:") : N("One of the following packages is needed:")),
                                    [ map { urpm_name($_) } @$choices ], $callback, nocancel => 1);
    defined $choices[0] ? $choices->[$choices[0]] : undef;
}

sub deps_msg {
        return 1 if $dont_show_selections->[0];
        my ($title, $msg, $nodes, $nodes_with_deps) = @_;
        my @deps = sort { $a cmp $b } difference2($nodes_with_deps, $nodes);
        @deps > 0 or return 1;
      deps_msg_again:
        my $results = interactive_msg(
            $title, $msg .
              format_list(map { scalar(urpm::select::translate_why_removed_one($urpm, $urpm->{state}, $_)) } @deps)
                . "\n\n" . format_size($urpm->selected_size($urpm->{state})),
            yesno => [ N("Cancel"), N("More info"), N("Ok") ],
            scroll => 1,
        );
        if ($results eq
		    #-PO: Keep it short, this is gonna be on a button
		    N("More info")) {
            interactive_packtable(
                N("Information on packages"),
                $::main_window,
                undef,
                [ map { my $pkg = $_;
                        [ gtknew('HBox', children_tight => [ gtkset_selectable(gtknew('Label', text => $pkg), 1) ]),
                          gtknew('Button', text => N("More information on package..."), 
                                 clicked => sub {
                                     interactive_msg(N("More information on package..."), get_info($pkg), scroll => 1);
                                 }) ] } @deps ],
                [ gtknew('Button', text => N("Ok"), 
                         clicked => sub { Gtk3->main_quit }) ]
            );
            goto deps_msg_again;
        } else {
            return $results eq N("Ok");
        }
}

sub toggle_nodes {
    my ($widget, $model, $set_state, $old_state, @nodes) = @_;
    @nodes = grep { exists $pkgs->{$_} } @nodes
      or return;
    #- avoid selecting too many packages at once
    return if !$dont_show_selections->[0] && @nodes > 2000;
    my $new_state = !$pkgs->{$nodes[0]}{selected};

    my @nodes_with_deps;

    my $bar_id = statusbar_msg(N("Checking dependencies of package..."), 0);

    my $warn_about_additional_packages_to_remove = sub {
        my ($msg) = @_;
        statusbar_msg_remove($bar_id);
        deps_msg(N("Some additional packages need to be removed"),
                 formatAlaTeX($msg) . "\n\n",
                 \@nodes, \@nodes_with_deps) or @nodes_with_deps = ();
    };
    
    if (member($old_state, qw(to_remove installed))) { # remove pacckages
        if ($new_state) {
            my @remove;
            slow_func($widget, sub { @remove = closure_removal(@nodes) });
            @nodes_with_deps = grep { !$pkgs->{$_}{selected} && !/^basesystem/ } @remove;
            $warn_about_additional_packages_to_remove->(
                N("Because of their dependencies, the following package(s) also need to be removed:"));
            my @impossible_to_remove;
            foreach (grep { exists $pkgs->{$_}{base} } @remove) {
                ${$pkgs->{$_}{base}} == 1 ? push @impossible_to_remove, $_ : ${$pkgs->{$_}{base}}--;
            }
            @impossible_to_remove and interactive_msg(N("Some packages cannot be removed"),
                                                      N("Removing these packages would break your system, sorry:\n\n") .
                                                        format_list(@impossible_to_remove));
            @nodes_with_deps = difference2(\@nodes_with_deps, \@impossible_to_remove);
        } else {
            slow_func($widget,
                      sub { @nodes_with_deps = grep { intersection(\@nodes, [ closure_removal($_) ]) }
                              grep { $pkgs->{$_}{selected} && !member($_, @nodes) } keys %$pkgs });
            push @nodes_with_deps, @nodes;
            $warn_about_additional_packages_to_remove->(
                N("Because of their dependencies, the following package(s) must be unselected now:\n\n"));
            $pkgs->{$_}{base} && ${$pkgs->{$_}{base}}++ foreach @nodes_with_deps;
        }
    } else {
        if ($new_state) {
            if (@nodes > 1) {
                #- unselect i18n packages of which locales is not already present (happens when user clicks on KDE group)
                my @bad_i18n_pkgs;
                foreach my $sel (@nodes) {
                    foreach ($pkgs->{$sel}{pkg}->requires_nosense) {
                        /locales-([^-]+)/ or next;
                        $sel =~ /-$1[-_]/ && !is_locale_available($_) and push @bad_i18n_pkgs, $sel;
                    }
                }
                @nodes = difference2(\@nodes, \@bad_i18n_pkgs);
            }
            
            my @requested;
            my $err_msg = "";
            slow_func(
                $widget,
                sub {
                    @requested = $urpm->resolve_requested(
                        open_rpm_db(), $urpm->{state},
                        { map { $pkgs->{$_}{pkg}->id => 1 } @nodes },
                        callback_choices => \&callback_choices,
                    );
                },
            );
            @nodes_with_deps = map { urpm_name($_) } @requested;
            my @ask_unselect = urpm::select::unselected_packages($urpm->{state});
            @nodes = (@nodes, difference2(\@ask_unselect, \@nodes));
            
            statusbar_msg_remove($bar_id);
            
	    if (my $conflicting_msg = urpm::select::conflicting_packages_msg($urpm, $urpm->{state})) {
                if (!interactive_msg(N("Conflicting Packages"), $conflicting_msg, yesno => 1, scroll => 1)) {
                    $err_msg = "Aborted.";
                    goto packages_selection_ok;
		}
	    }

            if (!deps_msg(N("Additional packages needed"),
                             formatAlaTeX(N("To satisfy dependencies, the following package(s) also need to be installed:\n\n")) . "\n\n",
                             \@nodes, \@nodes_with_deps)) {
                $err_msg = "Aborted.";
                goto packages_selection_ok;
            }
            
            #for old packages - this "if" based on "urpmi" source
            my $unselected_uninstalled = $urpm->{state}{unselected_uninstalled};
            if (ref($unselected_uninstalled) eq "ARRAY"){
                my @unselected_uninstalled = @{$unselected_uninstalled};
                my $tmp_list = join "\n", map { '- ' . $_->name . '-' . $_->version . '-' . $_->release  } @unselected_uninstalled;
                my $unselected_uninstalled_msg = @unselected_uninstalled == 1 ?
                    N("The following package cannot be installed because it depends on packages that are older than the installed ones:\n\n%s%s",
                        $tmp_list, length(@unselected_uninstalled))
                    : N("The following packages cannot be installed because they depend on packages that are older than the installed ones:\n\n%s%s",
                        $tmp_list, length(@unselected_uninstalled));
                $err_msg .= $unselected_uninstalled_msg;
                goto packages_selection_ok;
            }

            if (my @cant = sort(difference2(\@nodes, \@nodes_with_deps))) {
                my @reasons = map {
                    my $cant = $_;
                    my $unsel = find { $_ eq $cant } @ask_unselect;
                    $unsel
                      ? join("\n", urpm::select::translate_why_unselected($urpm, $urpm->{state}, $unsel))
                        : ($pkgs->{$_}{pkg}->flag_skip ? N("%s (belongs to the skip list)", $cant) : $cant);
                } @cant;
                my $count = @reasons;
                
                my $cannot_install_msg;
                $count == 1
                    ? $cannot_install_msg = N("Sorry, the following package cannot be selected:\n\n%s",
                                              format_list(@reasons))
                    : $cannot_install_msg = N("Sorry, the following packages cannot be selected:\n\n%s",
                                              format_list(@reasons));
                $err_msg .= $cannot_install_msg;
                foreach (@cant) {
                    next unless $pkgs->{$_}{pkg};
                    $pkgs->{$_}{pkg}->set_flag_requested(0);
                    $pkgs->{$_}{pkg}->set_flag_required(0);
                }
            }

          packages_selection_ok:
            if ($err_msg ne ""){
                @nodes_with_deps = ();
                $urpm->disable_selected(open_rpm_db(), $urpm->{state}, @requested);
                $urpm->{state}{rejected} = {};
                $urpm->{state}{unselected_uninstalled} = undef;
                if ($err_msg ne "Aborted.") { interactive_msg(N("Cannot select"),
                                                              $err_msg, scroll => 1); }
            }
    
        } else {
            my @unrequested;
            slow_func($widget,
                      sub { @unrequested = $urpm->disable_selected(open_rpm_db(), $urpm->{state},
                                                                   map { $pkgs->{$_}{pkg} } @nodes) });
            @nodes_with_deps = map { urpm_name($_) } @unrequested;
            statusbar_msg_remove($bar_id);
            if (!deps_msg(N("Some packages need to be removed"),
                             N("Because of their dependencies, the following package(s) must be unselected now:\n\n"),
                             \@nodes, \@nodes_with_deps)) {
                @nodes_with_deps = ();
                $urpm->resolve_requested(open_rpm_db(), $urpm->{state}, { map { $_->id => 1 } @unrequested });
                goto packages_unselection_ok;
            }
          packages_unselection_ok:
        }
    }
    
    foreach (@nodes_with_deps) {
        #- some deps may exist on some packages which aren't listed because
        #- not upgradable (older than what currently installed) #FIXED
        exists $pkgs->{$_} or next;
        if (!$pkgs->{$_}{pkg}) { #- cannot be removed  # FIXME; what about next packages in the loop?
            undef $pkgs->{$_}{selected};
            log::explanations("cannot be removed: $_");
        } else {
            $pkgs->{$_}{selected} = $new_state;
        }
        $set_state->($_, node_state($_), $model);
        if (my $pkg = $pkgs->{$_}{pkg}) {
            # FIXME: shouldn't we threat all of them as POSITIVE (as selected size)
            $size_selected += $pkg->size * ($pkg->flag_installed && !$pkg->flag_upgrade ? ($new_state ? -1 : 1) : ($new_state ? 1 : -1));
        }
    }
}

sub is_there_selected_packages() {
    int(grep { $pkgs->{$_}{selected} } keys %$pkgs);
}

sub real_quit() {
    if (is_there_selected_packages()) {
        interactive_msg(N("Some packages are selected."), N("Some packages are selected.") . "\n" . N("Do you really want to quit?"), yesno => 1) or return;
    }
    Gtk3->main_quit;
}

sub do_action__real {
    my ($options, $callback_action, $o_info) = @_;
    require urpm::sys;
    if (!urpm::sys::check_fs_writable()) {
        $urpm->{fatal}(1, N("Error: %s appears to be mounted read-only.", $urpm::sys::mountpoint));
        return 1;
    }
    if (!$Rpmdrake::pkg::need_restart && !is_there_selected_packages()) {
        interactive_msg(N("You need to select some packages first."), N("You need to select some packages first."));
        return 1;
    }
    my $size_added = sum(map { if_($_->flag_selected && !$_->flag_installed, $_->size) } @{$urpm->{depslist}});
    if ($MODE eq 'install' && $size_free - $size_added/1024 < 50*1024) {
        interactive_msg(N("Too many packages are selected"),
                        N("Warning: it seems that you are attempting to add so many
packages that your filesystem may run out of free diskspace,
during or after package installation ; this is particularly
dangerous and should be considered with care.

Do you really want to install all the selected packages?"), yesno => 1)
          or return 1;
    }
    my $res = $callback_action->($urpm, $pkgs);
    if (!$res) {
        $force_rebuild = 1;
        pkgs_provider($options->{tree_mode}, if_($Rpmdrake::pkg::probe_only_for_updates, pure_updates => 1), skip_updating_mu => 1);
        reset_search();
        $size_selected = 0;
        (undef, $size_free) = MDK::Common::System::df('/usr');
        $options->{rebuild_tree}->() if $options->{rebuild_tree};
        gtktext_insert($o_info, '') if $o_info;
    }
    $res;
}

sub do_action {
    my ($options, $callback_action, $o_info) = @_;
    my $res = eval { do_action__real($options, $callback_action, $o_info) };
    my $err = $@;
    # FIXME: offer to report the problem into bugzilla:
    if ($err && $err !~ /cancel_perform/) {
        interactive_msg(N("Fatal error"),
                        N("A fatal error occurred: %s.", $err));
    }
    $res;
}

sub translate_group {
    join('/', map { translate($_) } split m|/|, $_[0]);
}

sub ctreefy {
    join('|', map { translate($_) } split m|/|, $_[0]);
}

sub _build_tree {
    my ($elems, @elems) = @_;
    #- we populate all the groups tree at first
    %$elems = ();
    # better loop on packages, create groups tree and push packages in the proper place:
    foreach my $pkg (@elems) {
        my $grp = $pkg->[1];
        # no state for groups (they're not packages and thus have no state)
        add_parent($grp, undef);
        $elems->{$grp} ||= [];
        push @{$elems->{$grp}}, $pkg;
    }
}


sub build_tree {
    my ($tree, $tree_model, $elems, $options, $force_rebuild, $flat, $mode) = @_;
    state $old_mode;
    $mode = $options->{rmodes}{$mode} || $mode;
    return if $old_mode eq $mode && !$force_rebuild;
    $old_mode = $mode;
    undef $force_rebuild;
    my @elems;
    my $wait; $wait = statusbar_msg(N("Please wait, listing packages...")) if $MODE ne 'update';
    gtkflush();
    {
        my @keys = @filtered_pkgs;
        if (member($mode, qw(all_updates security bugfix normal))) {
            @keys = grep {
                my ($name) = split_fullname($_);
                member($descriptions->{$name}{importance}, @$mandrakeupdate_wanted_categories)
                  || ! $descriptions->{$name}{importance};
            } @keys;
            if (@keys == 0) {
                add_node('', N("(none)"), { nochild => 1 });
                state $explanation_only_once;
                $explanation_only_once or interactive_msg(N("No update"),
                                                          N("The list of updates is empty. This means that either there is
no available update for the packages installed on your computer,
or you already installed all of them."));
                $explanation_only_once = 1;
            }
        }
        # FIXME: better do this on first group access for faster startup...
        @elems = map { [ $_, !$flat && ctreefy($pkgs->{$_}{pkg}->group) ] } sort_packages(@keys);
    }
    my %sortmethods = (
        by_size => sub { sort { $pkgs->{$b->[0]}{pkg}->size <=> $pkgs->{$a->[0]}{pkg}->size } @_ },
        by_selection => sub { sort { $pkgs->{$b->[0]}{selected} <=> $pkgs->{$a->[0]}{selected}
                                       || uc($a->[0]) cmp uc($b->[0]) } @_ },
        by_leaves => sub {
            # inlining part of MDK::Common::Data::difference2():
            my %l; @l{map { $_->[0] } @_} = ();
            my @pkgs_times = ('rpm', '-q', '--qf', '%{name}-%{version}-%{release}.%{arch} %{installtime}\n',
		    map { chomp_($_) } run_program::get_stdout('urpmi_rpm-find-leaves'));
            sort { $b->[1] <=> $a->[1] } grep { exists $l{$_->[0]} } map { chomp; [ split ] } run_rpm(@pkgs_times);
        },
        flat => sub { no locale; sort { uc($a->[0]) cmp uc($b->[0]) } @_ },
        by_medium => sub { sort { $a->[2] <=> $b->[2] || uc($a->[0]) cmp uc($b->[0]) } @_ },
    );
    if ($flat) {
        add_node($_->[0], '') foreach $sortmethods{$::mode->[0] || 'flat'}->(@elems);
    } else {
        if (0 && $MODE eq 'update') {
            add_node($_->[0], N("All")) foreach $sortmethods{flat}->(@elems);
            $tree->expand_row($tree_model->get_path($tree_model->get_iter_first), 0);
        } elsif ($::mode->[0] eq 'by_source') {
             _build_tree($elems, $sortmethods{by_medium}->(map {
                my $m = pkg2medium($pkgs->{$_->[0]}{pkg}, $urpm); [ $_->[0], $m->{name}, $m->{priority} ];
            } @elems));
        } elsif ($::mode->[0] eq 'by_presence') {
            _build_tree($elems, map {
                my $pkg = $pkgs->{$_->[0]}{pkg};
                [ $_->[0], $pkg->flag_installed ?
                    (!$pkg->flag_skip && $pkg->flag_upgrade ? N("Upgradable") : N("Installed"))
                      : N("Addable") ];
              } $sortmethods{flat}->(@elems));
        } else {
            _build_tree($elems, @elems);
        }
    }
    statusbar_msg_remove($wait) if defined $wait;
}

sub get_info {
    my ($key, $widget) = @_;
    #- the package information hasn't been loaded. Instead of rescanning the media, just give up.
    exists $pkgs->{$key} or return [ [ N("Description not available for this package\n") ] ];
    #- get the description if needed:
    exists $pkgs->{$key}{description} or slow_func($widget, sub { extract_header($pkgs->{$key}, $urpm, 'info', find_installed_version($pkgs->{$key}{pkg})) });
    format_pkg_simplifiedinfo($pkgs, $key, $urpm, $descriptions);
}

sub sort_callback {
    my ($store, $treeiter1, $treeiter2) = @_;
    URPM::rpmvercmp(map { $store->get_value($_, $pkg_columns{version}) } $treeiter1, $treeiter2);
}

1;
