
use v5.24;
use MP4::Info ();
use Path::Tiny qw( path );

my $FILE_EXT = qr{mp4|m4v}i;

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
    my $epnum = $info->{TRACKNUM} || $info->{TRKN}->[0];
    my ( $season ) = $info->{ALB} =~ /Season (\d+)/;
    my $show = $info->{ART};

    next unless $title && $show;

    my $name = sprintf '%s/%dx%02d %s.%s', $show, $season, $epnum, $title, $ext;

    my $dir = path( $name )->parent;
    $dir->mkpath unless $dir->is_dir;

    say "$path -> $name";
    $path->move( $name );
}

