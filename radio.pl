#!/usr/bin/env perl

use v5.30;
use warnings;
use Audio::StreamGenerator;
use Quantum::Superpositions::Lazy;
use Path::Tiny;

my $current = path(__FILE__)->dirname;
my $silence_file = "$current/silence.wav";

## CONFIG

# genres: directory name => weight
my %genres = (
	pop => 50,
	lofi => 5,
	rap => 2,
	misc => 0.1,
);

# silence - amount of time to broadcast silence
my $silence_duration = 60;

## END CONFIG

sub generate_silence
{
	my $silence_duration = shift;
	unlink $silence_file if -f $silence_file;
	`ffmpeg -f lavfi -i anullsrc=channel_layout=stereo -t $silence_duration $silence_file`;
}

sub open_icecast
{
	my $password = $ENV{ICECAST_PASSWORD};
	my $port = $ENV{ICECAST_PORT} // 8080;
	my $name = $ENV{ICECAST_PORT} // 'perl_radio.mp3';

	my $icecast = "icecast://source:${password}\@localhost:${port}/${name}";
	my $out_command = qq{
			ffmpeg -re -f s16le -acodec pcm_s16le -ac 2 -ar 44100 -i -  \\
			-acodec libmp3lame -ac 2 -b:a 192k -content_type audio/mpeg $icecast
	};

	open my $out_fh, '|-', $out_command;
	return $out_fh;
}

sub get_next_file
{
	state $last = [];

	my $pos = do {
		my @arr;
		for my $genre (keys %genres) {
			my $pos = superpos(glob "$current/radio/$genre/*.mp3");
			push @arr, [$genres{$genre}, $pos];
		}
		superpos(\@arr);
	};

	my $choice;
	while (($choice = $pos->reset->collapse) eq superpos(@$last)) {}
	push @$last, $choice;
	shift @$last while @$last > 10;

	return $choice;
}

sub get_new_source
{
	state $silence = 0;
	state $silence_pos = superpos([[2, 1], [3, 0]]);

	my $fullpath;
	if (!$silence) {
		$fullpath = get_next_file;
		say ((scalar localtime) . ": playing $fullpath");
		$silence = $silence_pos->reset->collapse;
	}
	else {
		$fullpath = $silence_file;
		$silence = 0;
	}

	my @ffmpeg_cmd = (
		'ffmpeg',
		'-i',
		$fullpath,
		'-loglevel', 'quiet',
		'-f', 's16le',
		'-acodec', 'pcm_s16le',
		'-ac', '2',
		'-ar', '44100',
		'-'
	);
	open my $source, '-|', @ffmpeg_cmd;
	return $source;
}

generate_silence $silence_duration;
my $icecast = open_icecast;

my $streamer = Audio::StreamGenerator->new(
	out_fh => $icecast,
	get_new_source => \&get_new_source,
);

$streamer->stream();
