use 5.010;
use strict;
use warnings;

use lib "./lib";
use utf8;
use FindBin;
use lib $FindBin::Bin.'/lib';

use WallpaperList;
use WPConfig;
use Cwd qw(abs_path);
use File::Copy;
use Time::HiRes;

# the below block, will stop duplicate instances of this program from running
# it may however not provide any feedback as to why, and will not work well
# with image pregeneration
# use Fcntl ':flock';
# say "huh";
# open my $self_lock, '<', $0 or die "Couldn't open self: $!";
# flock $self_lock, LOCK_EX | LOCK_NB or die "This script is already running";


my $TIME = Time::HiRes::time;
my $START_TIME = $TIME;

sub timing {
	my $ct = Time::HiRes::time;
	my $ret = sprintf "(%.3f | %.3f)", $ct - $TIME, $ct - $START_TIME;
	$TIME = $ct;
	return $ret;
}

sub say_timed {
	say @_, " ", timing
}

say_timed "Initialise";
my $INI = WPConfig::load($FindBin::Bin . "/") or die "could not load config";
WallpaperList::init($INI->{db_path},$INI->{wp_path});

if (!WallpaperList::max_pos()) {
	index_wp_path();
}

@ARGV or usage();
foreach (@ARGV) {
	when(undef) { usage() };
	when('delete') { delete_wp() };
	when('deleteall') { delete_all() };
	when('fav') { set_fav() };
	when('export') { export() };
	when('nsfw') { set_nsfw() };
	when('open') { open_wallpaper() };
	when('pregen') { pregenerate_wallpapers() };
	when('purge') { purge() };
	when('rand') { rand_wp() };
	when('reorder') { reorder_wp(); };
	when('rescan') { index_wp_path() };
	when('sketchy') { set_sketchy() };
	when('stat') { show_wp_stat() };
	when('teu') { teu() };
	when('upload') { upload() };
	when('vacuum') { vacuum() };
	when('voteup') { vote(1) };
	when('votedown') { vote(-1) };
	when(qr/^rand\s+(.+)/i) { display_query($1) };
	when(/-?\d+/) { change_wp($_)};
	default { usage() };
}

cleanup_generated_wallpapers();
say_timed "Done";

sub usage {
	say "\nThe following commandline options are available:\n";
	say "\tdelete - move to trash_path";
	say "\tdeleteall - move all matching delete_all_criteria to trash_path";
	say "\tfav - set favourite flag";
	say "\texport - export selection to export_path";
	say "\tnsfw - set the nsfw flag";
	say "\topen - opens the image";
	say "\tpregen - pregenerates an amount of wallpapers specified by pregen_amount";
	say "\tpurge - removes flags and votes from wallpaper";
	say "\trand - select a random wallpaper based on rand_criteria";
	say "\treorder - recreates the order of the wallpapers according to the order_criteria";
	say "\trescan - rescans the wp_path for wallpapers";
	say "\tsketchy - sets the nsfw level to sketchy";
	say "\tstat - displays statistics for the current image";
	say "\tteu - search with tineye";
	say "\tupload - upload to some image hoster and open link";
	say "\tvacuum - rebuild the database to reclaim free space";
	say "\tvoteup - vote wallpaper up";
	say "\tvotedown - vote wallpaper down";
	say "\t\"rand <query where clause>\" - executes the query and displays a random result";
	say "\t'number' - change wallpaper by that amount";
}

sub index_wp_path {
	say "Indexing wp_path ";
	WallpaperList::add_folder($INI->{wp_path});
	say_timed "Adding Random Order", ;
	WallpaperList::determine_order("position IS NULL AND vote IS NULL");
}

sub reorder_wp {
	say_timed "removing old order";
	WallpaperList::remove_order();
	say_timed "creating new order";
	WallpaperList::determine_order($INI->{order_criteria});
	$INI->{position} = 1;
	WPConfig::save();
}

sub set_fav {
	say "Fav: " . $INI->{current};
	WallpaperList::set_fav($INI->{current});
}

sub set_nsfw {
	say "NSFW: " . $INI->{current};
	WallpaperList::set_nsfw($INI->{current});
}

sub set_sketchy {
	say "Sketchy: " . $INI->{current};
	WallpaperList::set_sketchy($INI->{current});
}

sub purge {
	say "PURGE: " . $INI->{current};
	WallpaperList::purge($INI->{current});
}

sub show_wp_stat {
	my $stat = WallpaperList::get_stat($INI->{current});
	my $max_pos = WallpaperList::max_pos();
	say "STATS: ";
	say "\tlast position: ", $max_pos;
	foreach (keys %$stat) {
		say "\t$_: " . (defined $stat->{$_} ? $stat->{$_} : "undef");
	}
}

sub delete_wp {
	my $pos = shift // $INI->{position};
	my ($path,$sha) = get_data($pos);
	warn "could not get path" and return unless ($path);
	WallpaperList::mark_deleted($sha);
	_delete($path,$sha);
}

sub delete_all {
	my $list = WallpaperList::get_list('path IS NOT NULL AND sha1 IS NOT NULL AND (' . $INI->{delete_all_criteria} . ')');
	foreach (@$list) {
		WallpaperList::mark_deleted($_->[1]);
		_delete(@$_);
	}
}

sub _delete {
	my ($path,$sha) = @_;
	mkdir $INI->{trash_path} or die 'could not create folder'.$INI->{trash_path}.": $!" unless( -d $INI->{trash_path});
	say "Move: ". $path ." To " . $INI->{trash_path};
	open my $f, ">>", $INI->{trash_path} . '_map.txt' or die "could not open ". $INI->{trash_path} . '_map.txt:' . $!;
	print $f $sha . "=" . $path . "\n";
	close $f;
	move($INI->{wp_path} . $path,$INI->{trash_path} . $sha);
}

sub vote {
	my $vote = shift;
	say "Vote ($vote): " . $INI->{current};
	WallpaperList::vote($INI->{current},$vote);
}

sub rand_wp {
	say_timed "Select Random";
	display_query($INI->{rand_criteria});
}

sub change_wp {
	my $mv = shift;
	my $pos = $INI->{position} + $mv;
	my $max_pos = WallpaperList::max_pos();
	my ($rel_path,$sha);
	while (1) {
		warn "invalid position $pos" and return if ($pos < 1 or $pos > $max_pos);
		($rel_path,$sha) = get_data($pos);
		last if $sha and $rel_path;
		return unless $mv;
		$pos += $mv <=> 0;
	}

	say_timed "Change To:";
	say "\t$rel_path ($pos)";

	unless (gen_wp($rel_path,$sha,"set")) {
		return change_wp($mv <=> 0);
	}

	say_timed "Save Config";
	$INI->{current} = $sha;
	$INI->{position} = $pos;
	# set_wallpaper($rel_path, $sha);
	WPConfig::save();
}

sub gen_wp {
	my ($rel_path,$sha,$set_wp) = @_;

	# do not pregen anything, if no gen path
	if (! $INI->{gen_path}) {
		if ($set_wp) {
			# no gen path, but still should set wallpaper
			set_wallpaper($rel_path, $sha);
		}
		return 1;
	}

	my $path = $INI->{wp_path} . $rel_path;
	mkdir $INI->{gen_path} or die 'could not create folder'.$INI->{gen_path} .": $!" unless -e $INI->{gen_path};
	my $gen_path = $INI->{gen_path}  . $sha;
	if (! -e $gen_path ) {
		say_timed "Processing:";
		say "\t$rel_path";
		unless (-e $path) {
			say "\t$path does not exist, deleting from db" ;
			WallpaperList::mark_deleted($sha);
			return;
		}

		my $ret = exec_command($set_wp?"convert_set":"convert",
			path => $path,
			sha => $sha,
			gen_path => $gen_path,
			);

		#my $ret = system('wpt.exe', ':convert' . ($set_wp?'set':''), $path, "generated/$sha");

		if ($ret) { #returns true on failure
			say_timed "\twallpaper failed checks, removing from rotation";
			WallpaperList::vote($sha,-10000);
			WallpaperList::remove_position($sha);
			return;
		}

	}
	elsif($set_wp) {
		set_wallpaper($rel_path, $sha);
	}
	return 1;
}

sub exec_command {
	my ($type, %params) = @_;
	my $command = "";
	$command = $INI->{command_convert_set} if $type eq "convert_set";
	$command = $INI->{command_convert} if $type eq "convert";
	$command = $INI->{command_set} if $type eq "set";
	die "unknown command type: $type" unless $command;

	for my $key (keys %params) {
		$command =~ s/\{$key\}/$params{$key}/egi;
	}

	say_timed "Executing $command";

	return system($command);
}

sub cleanup_generated_wallpapers {
	say_timed "Cleanup";
	opendir(my $dh, $INI->{gen_path}) or return;
	my @dir = grep {-f $INI->{gen_path}.$_ and $_ =~ /^\w+$/ and $_ ne $INI->{current}} readdir($dh);
	closedir $dh;
    foreach my $file (@dir) {
		my $pos = WallpaperList::get_pos($file);
		my $lower = $INI->{position} - $INI->{pregen_amount};
		my $upper = $INI->{position} + $INI->{pregen_amount};
		unlink $INI->{gen_path}.$file if !$pos or $pos < $lower or $pos > $upper;
	}
}

sub pregenerate_wallpapers {
	lock_check('pregen') or return;
	lock_set('pregen');
	say_timed "Pregenerating";
 	my $count = $INI->{pregen_amount};
	my $pos = $INI->{position};
	while($count--) {
		my ($path,$sha) = get_data(++$pos);
		next unless $path and $sha;
		gen_wp($path,$sha);
	}
	lock_release('pregen');
}

sub get_data {
	my ($pos, $qpath) = @_;
	my ($path, $sha, $double) = $pos ?
		WallpaperList::get_data($pos) :
		WallpaperList::gen_sha($qpath);
	if ($double) {
		say "$path has same sha as $double";
		_delete($path,$sha);
		return (undef,undef)
	}
	return ($path,$sha);
}

sub set_wallpaper {
	my ($rel_path, $sha) = @_;
	# say_timed "Set Wallpaper $sha $rel_path";
	# Wallpaper::setWallpaper($INI->{gen_path} . $wp);
	exec_command("set",
		path => $INI->{wp_path} . $rel_path,
		sha => $sha,
		gen_path => $INI->{gen_path} . $sha,
		);
	#system('wpt.exe', ':set', $INI->{gen_path} . $wp);
	return 1;
}

sub export {
	my $export_dir = $INI->{export_path};
	my $export_criteria = $INI->{export_criteria};

	say "copy selected to $export_dir";
	mkdir $export_dir or die 'could not create folder'.$export_dir.": $!" unless -e $export_dir;
	my $selected = WallpaperList::get_list($export_criteria);

	foreach (@$selected) {
		say $_->[0];
		copy($INI->{wp_path} . $_->[0],$export_dir);
	}
}

sub upload {
	require UploadTools;
	my $sha = $INI->{current};
	my $path = WallpaperList::get_path($sha);
	$path = $INI->{wp_path} . $path;
	UploadTools::upload($path);
}

sub teu {
	require UploadTools;
	my $sha = $INI->{current};
	my $path = WallpaperList::get_path($sha);
	$path = $INI->{wp_path} . $path;
	UploadTools::teu($path);
}

sub open_wallpaper {
	my $sha = $INI->{current};
	my $path = WallpaperList::get_path($sha);
	say_timed "Calling system";
	system($INI->{wp_path} . $path );
}

sub lock_check {
	my $lock = shift;
	return !-e $lock;
}

sub lock_set {
	my $lock = shift;
	my $r = open my $f, '>', $lock;
	close $f;
	return $r;
}

sub lock_release {
	my $lock = shift;
	return unlink $lock;
}

sub display_query {
	my ($query) = @_;
	say_timed "Select randomly from query";
	my $fav = WallpaperList::get_list('path IS NOT NULL AND (' . $query. ')', "ORDER BY RANDOM() LIMIT 1");
	warn "nothing matching criteria" and return unless @$fav;
	my $sel = $fav->[0];
	my ($path, $sha) = @$sel;
	($path, $sha) = get_data(0, $path) if $path and not $sha;
	say_timed "Selected " . $path;
	gen_wp($path,$sha, 'set') or return;
	say_timed "SAVE CONFIG";
	$INI->{current} = $sha;
	WPConfig::save();
}

sub vacuum {
	say_timed "vacuum wallpaper list";
	WallpaperList::vacuum();
}
