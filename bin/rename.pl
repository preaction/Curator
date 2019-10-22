
use v5.24;
use MP4::Info ();
use Path::Tiny qw( path );
use FindBin qw( $Bin );
use autodie qw( :all );

my $FILE_EXT = qr{mp4|m4v}i;
my $DEST_ROOT = path( shift @ARGV );
my $TV_ROOT = $DEST_ROOT->child( 'TV' );
my $MOVIE_ROOT = $DEST_ROOT->child( 'Movies' );

die "$DEST_ROOT does not exist" unless $DEST_ROOT->exists;
die "$TV_ROOT does not exist" unless $TV_ROOT->exists;
die "$MOVIE_ROOT does not exist" unless $MOVIE_ROOT->exists;
if ( !@ARGV ) {
    unshift @ARGV, $DEST_ROOT;
}
walk_paths( @ARGV );

sub walk_paths {
    my ( @paths ) = @_;
    for my $path_str ( @paths ) {
        my $path = path( $path_str );
        if ( -f $path ) {
            rename_file( $path );
        }
        if ( -d $path ) {
            walk_paths( $path->children );
        }
    }
}

sub rename_file {
    my ( $path ) = @_;
    return unless $path =~ /[.]($FILE_EXT)$/;
    my $ext = $1;

    my $info = MP4::Info->new( "$path" );

    # Sanity checks to make sure this is actually complete metadata
    if ( grep !defined, $info->@{qw( TITLE ARTIST YEAR GENRE META )} ) {
        next;
    }

    my $title = $info->{TITLE} || $info->{NAM};
    $title =~ s/:/ -/g;
    $title =~ s{/}{-}g;
    my $epnum = $info->{TRACKNUM} || $info->{TRKN}->[0];
    my ( $season ) = $info->{ALB} =~ /Season (\d+)/;
    my $show = ucfirst $info->{ART};

    # ; say $path;
    # ; use Data::Dumper;
    # ; delete $info->{COVR};
    # ; say Dumper $info;
    # ; next;

    my $move_to;
    if ( $season ) {
        $show =~ s/\s+$//;
        $show =~ s/:/ -/g;
        my $name = sprintf '%s/%dx%02d %s.%s', $show, $season, $epnum, $title, $ext;
        $move_to = $TV_ROOT->child( $name );
        my $dir = $move_to->parent;
        $dir->mkpath unless $dir->is_dir;
    }
    else {
        my $name = sprintf '%s.%s', $title, $ext;
        $name =~ s/:/ -/g;
        $move_to = $MOVIE_ROOT->child( $name );
    }

    next if $path eq $move_to;
    if ( -e $move_to ) {
        my $dup_info = MP4::Info->new( "$move_to" );
        # Check these fields for equality
        my @fields = qw( TITLE NAM TRACKNUM ALB ART YEAR );
        if ( !grep { $dup_info->{$_} ne $info->{$_} } @fields ) {
            say "\t$move_to already exists and has the same metadata... Skipping.";
            return;
        }
        $move_to = path( $move_to =~ s/([.][^.]+)$/ ($info->{YEAR})$1/r );
    }

    say "$path -> $move_to";
    my $copy = $path->copy( $move_to );
    if ( $copy && $path ne $move_to ) {
        $path->remove;
        system path( $Bin, 'itunes', 'add-to-library.applescript' ), "$copy";
    }
}

