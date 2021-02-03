# Minimal personal radio streamer

Requires Icecast configured and running.

Songs go to `./radio/genre/song.mp3`. Weights for genres can be configured in `config.pl`.
Execute `cp config.pl.sample config.pl` before running the program.

60 seconds of silence is generated and mixed in every few songs.

Daemonized by Ubic - `mkdir log` before running the daemon.
