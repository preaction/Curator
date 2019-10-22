#!/usr/bin/perl
# PODNAME: rip.pl

use strict;
use warnings;
use feature qw( say );

use File::Copy;
use File::Path;
use File::Spec;
use File::Find;
use IPC::Open3 qw( open3 );
use File::Basename qw( basename );
use Getopt::Long;
use FindBin qw( $Bin );
use Cwd qw( abs_path );

GetOptions(
    'dvd' => \( my $dvd ),          # Only rip DVDs?
);

# XXX: Signal should stop current rip

my $ENCODE_FOLDER	= abs_path( shift @ARGV );
my @dirs = @ARGV ? @ARGV : ( "/Volumes" );
my $DVD_TODO  		= File::Spec->tmpdir;

my $MIN_TRACK_TIME	= "10";	# In minutes
my $HANDBRAKE		= "/Applications/HandBrakeCLI";
my $HB_PRESET		= q{Apple 1080p30 Surround};
my $OUTPUT_FORMAT	= "m4v";

my $POLL_INTERVAL	= 1200;
my $TV_DEVIANCE		= 10; # Minutes deviance between titles for TV dvds
my $TV_MIN_EPS		= 2; # Minimum number of eps per disk

my $FORCE_TV = 0; # Force TV mode. Rip a bunch of things.

open my $LOG_FILE, ">>", "$Bin/../var/log/rip.log" or die "Couldn't open logfile! $!\n";
select $LOG_FILE; $|++;
sub print_log(@) {
	print $LOG_FILE scalar( localtime ), " - $$ - ", @_, "\n";
}

# -5 -- Decomb if necessary
# -m -- Add chapter markers
my @HB_ARGS = ( '--preset', $HB_PRESET, '-5', '-m' );

# -N eng -- Native language
# --native-dub -- Use native language for audio, not subtitles
my @HB_NATIVE = ( '-N', 'eng', '--native-dub' );

# --subtitle scan -- Find subtitles used for less than 10% of the time
#       Except this doesn't appear to actually work for whatever reason
#       Maybe because the source only has the forced subtitles already
# -F -- Only use forced subtitles
# --subtitle-default -- Set the default subtitle
my @HB_SUBS = ( '--subtitle', 'scan', '-F' );

my $max_depth = $dvd ? 1 : 4;
# Looking for VIDEO_TS and .avi, .mkv, .mov, .ogg, .m4v
find({
    preprocess => sub {
        my $cwd = find_rel_dir( $File::Find::dir );
        my $depth = $cwd =~ tr[/][];
        return @_ if $depth <= $max_depth;
        return;
    },
    wanted => sub {
        my $file = $_;
        if ( $file =~ /[.](mp4|avi|mkv|m4v|mov|ogg|mpg|m?ts|iso)$/i or -d "$file/VIDEO_TS" ) {
            if ( -d "$file/VIDEO_TS" || $file =~ /[.]iso$/i ) {
                rip_dvd( $file, find_rel_dir( $File::Find::dir ) );
            }
            elsif ( !$dvd ) {
                my $dir = find_rel_dir( $File::Find::dir );
                rip_file( $file, $dir );
            }
            if ( -d "$file/VIDEO_TS" ) {
                print_log "Done, ejecting volume";
                print_log `diskutil eject "$File::Find::name" 2>&1`;
            }
        }
    },
}, @dirs );

sub find_rel_dir {
    my ( $path ) = @_;
    for my $dir ( @dirs ) {
        if ( $path =~ /^\Q$dir/ ) {
            $path =~ s/\Q$dir//;
            return $path;
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

sub get_title_info {
    my ( $canon_path ) = @_;
    my $title_info = `$HANDBRAKE -i "${canon_path}" -t 0 2>&1`;
    if ( $? ) {
        print_log "Problem running $HANDBRAKE: $?";
    }
    return $title_info;
}

sub rip_dvd {
    my ( $in_file, $dir ) = @_;
    my $canon_path;
    if ( -f $in_file ) {
        $canon_path = $in_file;
    }
    else {
        $canon_path = $in_file . "/VIDEO_TS";
    }

    # Find all titles we want
    print_log "Discovering title information";
    my $title_info = get_title_info( $canon_path ) || return;

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

        print_log "Making $in_file title $title_number... ";

        `mkdir -p "$ENCODE_FOLDER/$dir"`;
        my $out_file = find_unique_name( "$ENCODE_FOLDER/$dir/${title_number}", ${OUTPUT_FORMAT} );

        # Run HandBrakeCLI
        my @args = ( '-i', $in_file, '-t', $title_number, '-o', $out_file );
        run_handbrake( @args );

        # XXX: Check for failure
    }
}

sub rip_file {
    my ( $in_file, $folder ) = @_;

    print_log "Making $folder/$in_file... ";

    # Remove the original format extension
    my $out_fn = $in_file;
    $out_fn =~ s/[.][^.]+$//;

    `mkdir -p "$ENCODE_FOLDER/$folder"`;
    my $out_file = find_unique_name( "$ENCODE_FOLDER/$folder/${out_fn}", $OUTPUT_FORMAT );

    # Scan the title to find out if we need to add subtitle arguments
    my $title_info = get_title_info( $in_file );
    my @lines = split /\n/, $title_info;
    my %audio;
    my $in_audio = 0;

    for my $line ( @lines ) {
        if ( !$in_audio ) {
            # Look for the first "  + audio tracks:" line
            $in_audio = $line =~ /\s{2}\+\s+audio tracks:/;
            next;
        }

        # ... and keep looking until there are less than 4 spaces
        $in_audio = $line =~ /\s{4}\+/;
        last if !$in_audio;

        my ( $no, $lang, $code ) = $line =~ /(\d+), (\S+).+\(iso639-2: (\w+)\)/;
        $audio{ $code } = $no;
    }
    #print_log( "Found audio: " . join ", ", sort { $audio{$a} <=> $audio{$b} } keys %audio );

    my %subtitle;
    my $in_subtitle = 0;
    for my $line ( @lines ) {
        if ( !$in_subtitle ) {
            # Look for the first "  + subtitle tracks:" line
            $in_subtitle = $line =~ /\s{2}\+\s+subtitle tracks:/;
            next;
        }

        # ... and keep looking until there are less than 4 spaces
        $in_subtitle = $line =~ /\s{4}\+/;
        last if !$in_subtitle;

        my ( $no, $lang, $code ) = $line =~ /(\d+), (\S+).+\(iso639-2: (\w+)\)/;
        next if !$code;
        $subtitle{ $code } = $no;
    }

    # Run HandBrakeCLI
    my @args = ( '-i', $in_file, '-o', $out_file );
    if ( $audio{ und } && !$audio{ eng } ) {
        print_log(
            sprintf "No English audio. Unknown audio track: %s; Unknown subtitle track: %s",
            $audio{und}//'', $subtitle{und}//'',
        );
        push @args, '--subtitle', join ',', grep { defined } $subtitle{und}, $subtitle{eng};
    }
    else {
        my @audio_langs = sort { $audio{ $a } <=> $audio{ $b } } keys %audio;
        my @subtitle_langs = sort { $subtitle{ $a } <=> $subtitle{ $b } } keys %subtitle;
        print_log( "Adding native language option. Audio langs: @audio_langs; Subtitle langs: @subtitle_langs" );
        push @args, @HB_NATIVE;
    }
    run_handbrake( @args );
    # XXX: Check for failure
}

sub run_handbrake {
    my ( @args ) = @_;

    # HandBrakeCLI drains STDIN, so let's give it something to drain...
    # Need bareword filehandles to get open3 to link up STDOUT/STDERR without closing them
    ## no critic ( 'ProhibitNoWarnings', 'ProhibitBarewordFilehandles' )
    no warnings 'once';
    open IN, '<', '/dev/null' or die "Could not open /dev/null: $!";
    open OUT, '>/dev/null' or die "Could not dup /dev/null: $!";
    open ERR, '>/dev/null' or die "Could not dup /dev/null: $!";
    my $pid = open3 '<&IN', '>&OUT', '>&ERR', 'nice', $HANDBRAKE, @HB_ARGS, @HB_SUBS, @args;
    wait; # waitpid doesn't seem to actually wait for some reason...
}

