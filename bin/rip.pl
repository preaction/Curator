#!/usr/bin/perl

use strict;
use warnings;

use File::Copy;
use File::Path;
use File::Spec;
use File::Find;
use File::Basename qw( basename );
use Getopt::Long;

GetOptions(
    'dvd' => \( my $dvd ),          # Only rip DVDs?
);


# XXX: Signal should stop current rip

my $ENCODE_FOLDER	= shift @ARGV;
my @dirs = @ARGV ? @ARGV : ( "/Volumes" );
my $DVD_TODO  		= File::Spec->tmpdir;

my $MIN_TRACK_TIME	= "10";	# In minutes
my $HANDBRAKE		= "/Applications/HandBrakeCLI";
my $HB_PRESET		= q{AppleTV 2};
my $OUTPUT_FORMAT	= "m4v";

my $POLL_INTERVAL	= 1200;
my $TV_DEVIANCE		= 10; # Minutes deviance between titles for TV dvds
my $TV_MIN_EPS		= 2; # Minimum number of eps per disk

my $FORCE_TV = 0; # Force TV mode. Rip a bunch of things.

open my $LOG_FILE, ">>", "$ENV{HOME}/Movies/drivetrain.log" or die "Couldn't open logfile! $!\n";
select $LOG_FILE; $|++;
sub print_log(@) {
	print $LOG_FILE scalar( localtime ), " - $$ - ", @_, "\n";
}

# Looking for VIDEO_TS and .avi, .mkv, .mov, .ogg
find( sub {
    my $file = $_;
    if ( $file =~ /[.](mp4|avi|mkv|mov|ogg|mpg|m?ts|iso)$/i or -d "$file/VIDEO_TS" ) {
        if ( -d "$file/VIDEO_TS" || $file =~ /[.]iso$/ ) {
            rip_dvd( $file, $file );
        }
        elsif ( !$dvd ) {
            rip_file( $file, basename( $File::Find::dir ) );
        }
        if ( -d "$file/VIDEO_TS" ) {
            print_log "Done, ejecting volume";
            `diskutil eject "$File::Find::name"`;
        }
    }
}, @dirs );

sub wait_for_handbrake {
    while ( 1 ) {
        my $process_list = `ps ax`;
        if ( $process_list !~ /$HANDBRAKE/ ) {
            last;
        }
        else {
            print_log "$HANDBRAKE already running... sleeping $POLL_INTERVAL seconds";
            sleep $POLL_INTERVAL;
        }
    }
}

sub find_unique_name {
    my ( $out_file, $format ) = @_;
    if ( -e $out_file . ".${format}") { 
            # Add numbers until we can make it
            my $counter = 1;
            while ( -e $out_file . "_$counter.${format}") {
                    $counter++;
            }
            $out_file .= "_$counter";
    }
    return "${out_file}.${format}";
}

sub rip_dvd {
    my ( $in_file, $volume ) = @_;
    my $canon_path;
    if ( -f $in_file ) {
        $canon_path = $in_file;
    }
    else {
        $canon_path = $in_file . "/VIDEO_TS";
    }

    # Find all titles we want
    print_log "Discovering title information";
    my $title_info = `$HANDBRAKE -i "${canon_path}" -t 0 2>&1`;
    if ( $? ) {
        print_log "Problem running $HANDBRAKE: $?";
    }

    # TV: 3-8 titles within 3-4 minutes of each other, and 
    #     maybe one title with all the other titles
    # Movie: 1 title with large time, maybe other smaller ones
    my @titles;
    while ( $title_info =~ /[+] title (\d+):.+?[+] duration: ([\d:]+)/gs ) {
        my $title_number = $1;
        my ( $hours, $minutes ) = $2 =~ /(\d+):(\d+)/;
        my $length	= $hours * 60 + $minutes;
        next if ( $length < $MIN_TRACK_TIME );
        print_log sprintf "Title: %4s, Length: %6s", $title_number, $length;
        push @titles, {
            id	=> $title_number,
            length	=> $length,
        };
    }
    my $longest	= (sort { $b->{length} <=> $a->{length} } @titles)[0];
    # Find titles within 5 minutes of each other
    for my $i ( 0..$#titles ) {
        my $cur_title = $titles[$i];
        $cur_title->{idx_similar} = [];
        INNER: for my $x ( 0..$#titles ) {
            next INNER if $i == $x;
            my $diff = $cur_title->{length} - $titles[$x]->{length};
            if ( $diff <= $TV_DEVIANCE && $diff >= -$TV_DEVIANCE ) {
                push @{$cur_title->{idx_similar}}, $x;
            }
        }
    }

    # Add title lengths together
    my $most = (sort {
            scalar @{$b->{idx_similar}} <=> scalar @{$a->{idx_similar}} 
        } @titles )[0];
    my $similar_total = $most->{length};
    for my $t ( @{$most->{idx_similar}} ) {
            $similar_total += $titles[$t]->{length};
    }

    my @titles_to_rip;
    # If more than half are similar
    if ( $FORCE_TV || @titles > 1 && @{$most->{idx_similar}} >= $TV_MIN_EPS && @{$most->{idx_similar}} > @titles / 2 - 1 ) {
            print_log sprintf "Type: TV ( Eps: %3s Total: %3s )", 
                    scalar( @{$most->{idx_similar}} + 1 ), scalar( @titles );
            @titles_to_rip = ( 
                    map { $_->{id} } $most, @titles[@{$most->{idx_similar}}]
            );
    }
    else {
            print_log "Type: Movie";
            @titles_to_rip = $longest->{id};
    }

    for my $title_number ( @titles_to_rip ) {
        wait_for_handbrake;

        print_log "Making $volume title $title_number... ";

        `mkdir -p "$ENCODE_FOLDER/$volume"`;
        my $out_file = find_unique_name( "$ENCODE_FOLDER/$volume/${title_number}", ${OUTPUT_FORMAT} );

        # Run HandBrakeCLI
        # -5 -- Decomb if necessary
        # -F -- show forced subtitles
        # -N eng -- Native language
        # --native-dub -- Use native language for audio, not subtitles
        # --subtitle scan -- Find subtitles used for less than 10% of the time
        system 'nice', $HANDBRAKE, '-v9', '--preset', $HB_PRESET, '-5', '-F', '-N', 'eng', 
                '--native-dub', '--subtitle', 'scan',
                '-i', $in_file, '-t', $title_number, '-o', $out_file;

        # XXX: Check for failure
    }
}

sub rip_file {
    my ( $in_file, $folder ) = @_;

    wait_for_handbrake;
    print_log "Making $folder/$in_file... ";

    `mkdir -p "$ENCODE_FOLDER/$folder"`;
    my $out_file = find_unique_name( "$ENCODE_FOLDER/$folder/${in_file}", $OUTPUT_FORMAT );

    # Run HandBrakeCLI
    # -5 -- Decomb if necessary
    # -F -- show forced subtitles
    # -N eng -- Native language
    # --native-dub -- Use native language for audio, not subtitles
    # --subtitle scan -- Find subtitles used for less than 10% of the time
    system 'nice', $HANDBRAKE, '-v9', '--preset', $HB_PRESET, '-5', '-F', '-N', 'eng', 
            '--native-dub', '--subtitle', '1', '-i', $in_file, '-o', $out_file;

    # XXX: Check for failure
}
