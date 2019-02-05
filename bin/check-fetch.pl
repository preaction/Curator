
use v5.24;
use warnings;
use Mojo::File qw( path );
use YAML;
use FindBin qw( $Bin );
use Bencode qw( bdecode );
use Data::Dumper qw( Dumper );
use List::Util qw( any all );
use Cwd qw( cwd );
use Getopt::Long qw( GetOptions );

$|++;

GetOptions( \my %opt, 'done' );
my $CWD = cwd();
my $state_file = path( $Bin )->sibling( var => 'check-state.yml' );
my $state = -f $state_file ? YAML::LoadFile( "$state_file" ) : {};
my $torrents_dir = path( $Bin )->sibling( var => 'torrent' );
my $downloads_dir = path( '/Volumes/WD3000/Download' );
my $tmp_dir = path( $Bin )->sibling( 'tmp' );
my $done_dir = path( $Bin )->sibling( 'var', 'done' );

my @torrents = sort +( @ARGV ? map { path( $_ ) } @ARGV : $torrents_dir->list->each );

# Check to see if a torrent is done
TORRENT: for my $file ( @torrents ) {
    my $basename = $file->basename( '.torrent' );
    #; say $basename;

    my $data = eval { bdecode( $file->slurp ) };
    if ( $@ ) {
        say "Can't parse $file: $@";
        next;
    }
    if ( !$data->{info} ) {
        ; say "Torrent file has no {info} section!";
        next TORRENT;
    }

    $basename = $data->{info}{name} || $basename;
    next if $state->{ $basename } && $state->{ $basename } =~ /transcoded|deleted/;

    #; say Dumper { $data->{info}->%{ grep { !/pieces/ } keys $data->{info}->%* } };
    my $files = $data->{info}{files} || [ { $data->{info}->%{qw( name length ) } } ];
    if ( !$files ) {
        ; say "Torrent $file has no files!";
        next TORRENT;
    }
    #; say Dumper $data->{info}{files};

    # Look in the list of files in the torrent and see if they are all
    # there
    my @files;
    for my $file ( $files->@* ) {
        if ( $file->{name} ) {
            push @files, $downloads_dir->child( $file->{name} );
        }
        else {
            push @files, $downloads_dir->child( $basename, $file->{path}->@* );
        }
    }

    #; say Dumper \@files;
    if ( my @files = grep { !-e } @files ) {
        ; say "Not finished: $basename ($file)";
        ; say "\tMissing: $_" for @files;
        #; say "Files missing: " . join "\n", grep { !-e } @files;
        #; say "Files avail: " . join "\n", grep { -e } @files;
        if ( $opt{done} && all { !-e } @files ) {
            ; say "All files missing, assuming deleted";
            update_state( $basename, "deleted" );
        }
        else {
            update_state( $basename, "downloading" );
        }
        next TORRENT;
    }

    # If we're assuming done, just update state
    if ( $opt{ done } ) {
        update_state( $basename, "transcoded" );
        next TORRENT;
    }

    # If done, copy the files locally
    my $remote_path = @files == 1 ? $files[0] : $downloads_dir->child( $basename );
    if ( !$state->{ $basename } || $state->{ $basename } !~ /copied|extracted|transcoded|deleted/ ) {
        ; say "Copying $basename to $tmp_dir";
        system( 'rsync', '-a', $remote_path, $tmp_dir );
        if ( $? ) {
            ; say "Problem copying $remote_path to $tmp_dir";
            next TORRENT;
        }
        update_state( $basename, "copied" );
    }

    my $local_path = $tmp_dir->child( $remote_path->basename );
    # Run the extractor, if necessary
    if ( $state->{ $basename } !~ /extracted|transcoded|deleted/ ) {
        ; say "Extracting $local_path";
        #; say "running : " . path( $Bin )->child( 'extract.pl' );
        system( $^X, path( $Bin )->child( 'extract.pl' ), $local_path );
        if ( $? ) {
            ; say "Problem extracting $local_path";
            next TORRENT;
        }
        update_state( $basename, "extracted" );
    }

    # Run the ripper
    if ( $state->{ $basename } !~ /transcoded|deleted/ ) {
        ; say "Transcoding $local_path";
        system( $^X, path( $Bin )->child( 'rip.pl' ), $done_dir, $local_path );
        if ( $? ) {
            ; say "Problem transcoding $local_path";
            next TORRENT;
        }
        update_state( $basename, "transcoded" );
    }

    # Delete the local files
    if ( -e $local_path ) {
        ; say "Removing $local_path";
        $local_path->remove_tree;
    }
}

sub update_state {
    my ( $basename, $file_state ) = @_;
    $state->{ $basename } = $file_state;
    YAML::DumpFile( "$state_file", $state );
}

