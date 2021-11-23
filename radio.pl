#!/usr/bin/env perl

use v5.30;
use warnings;
use Audio::StreamGenerator;
use Q::S::L qw(superpos fetch_matches every_state);
use Path::Tiny;
use JSON::MaybeXS;

my $current = path(__FILE__)->dirname;
my $silence_file = "$current/silence.wav";
my $config = require "$current/config.pl";

sub get_control_data
{
	my $filename = $config->{control_filename};

	return {}
		unless -f $filename;

	my $data = path($filename)->slurp;
	return decode_json($data);
}

sub generate_silence
{
	my $silence_duration = shift;
	unlink $silence_file if -f $silence_file;
	`ffmpeg -f lavfi -i anullsrc=channel_layout=mono -t $silence_duration $silence_file`;
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
	my ($control) = @_;
	state $last = [];
	my @genres = ($control->{genres} // [keys $config->{genres}->%*])->@*;

	my $pos = do {
		my @arr;
		my $last_files = superpos($last->@*);
		for my $genre (@genres) {
			my $prob = $config->{genres}{$genre};
			next unless defined $prob;

			my @all_files = glob "$current/radio/$genre/*.mp3";
			my $total = @all_files;

			my $pos = superpos(@all_files);
			$pos = fetch_matches { every_state { $pos ne $last_files } };

			if (!$pos->states->@*) {
				$pos = superpos(@all_files);
				$last = [grep { every_state { $_ ne $pos } } $last->@*];
			}

			push @arr, [$prob * $total, $pos];
		}
		superpos(\@arr);
	};

	my $choice = $pos->collapse;
	push @$last, $choice;

	return $choice;
}

sub get_new_source
{
	my $control = get_control_data;
	state $silence = 0;
	state $silence_pos = superpos([[$config->{silence_chance}, 1], [1 - $config->{silence_chance}, 0]]);

	my $fullpath;
	if (!$silence || $control->{no_silence}) {
		$fullpath = get_next_file $control;
		say ((scalar localtime) . ": playing $fullpath");
		$silence = $silence_pos->reset->collapse;
	}
	else {
		$fullpath = $silence_file;
		$silence = 0;
	}

	my $set_rate = sub {
		my $category = path($fullpath)->parent->basename;
		my $normal_rate = 44100;
		my $conf = $config->{slowed_genres}{$category};

		if ($conf) {
			my ($chance, $tones) = $conf->@*;
			my $slowed_rate = int($normal_rate * 2 ** ($tones / 12));
			return superpos([
				[$chance, $slowed_rate],
				[1 - $chance, $normal_rate],
			]);
		}
		else {
			return superpos($normal_rate);
		}
	};

	my @ffmpeg_cmd = (
		'ffmpeg',
		'-i',
		$fullpath,
		'-loglevel', 'quiet',
		'-f', 's16le',
		'-acodec', 'pcm_s16le',
		'-ac', '2',
		'-ar', $set_rate->()->collapse,
		'-'
	);

	open my $source, '-|', @ffmpeg_cmd;
	return $source;
}

generate_silence $config->{silence_duration};
my $icecast = open_icecast;

my $streamer = Audio::StreamGenerator->new(
	out_fh => $icecast,
	get_new_source => \&get_new_source,
);

$streamer->stream();
