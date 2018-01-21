
use v5.24;
use MP4::Info ();
use Path::Tiny qw( path );

my $FILE_EXT = qr{mp4|m4v}i;
my $DEST_ROOT = path( shift @ARGV );
die "$DEST_ROOT does not exist" unless $DEST_ROOT->exists;
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
    # ; say $path;
    # ; use Data::Dumper;
    # ; delete $info->{COVR};
    # ; say Dumper $info;

    my $title = $info->{TITLE} || $info->{NAM};
    $title =~ s/:/ -/g;
    my $epnum = $info->{TRACKNUM} || $info->{TRKN}->[0];
    my ( $season ) = $info->{ALB} =~ /Season (\d+)/;
    my $show = $info->{ART};

    next unless $title;

    my $move_to;
    if ( $season ) {
        $show =~ s/\W+$//;
        $show =~ s/:/ -/g;
        my $name = sprintf '%s/%dx%02d %s.%s', $show, $season, $epnum, $title, $ext;
        $move_to = $DEST_ROOT->child( $name );
        my $dir = $move_to->parent;
        $dir->mkpath unless $dir->is_dir;
    }
    else {
        my $name = sprintf '%s.%s', $title, $ext;
        $name =~ s/:/ -/g;
        $move_to = $DEST_ROOT->child( $name );
    }

    say "$path -> $move_to";
    $path->move( $move_to );
}

