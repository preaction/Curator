
use strict;
use warnings;

use Cwd qw( getcwd abs_path chdir );
use File::Basename qw( basename );
use File::Find;
use File::Spec::Functions qw( catdir );
use IO::CaptureOutput qw( capture );
use Archive::Zip;
use feature 'say';

$|++;

my %formats = (
    rar     => [ qr/[.]cbr$/, qr/[.]part0*1[.]rar$/, qr/(?:(?<![.]part\d\d\d)|(?<![.]part\d\d))[.]rar$/, ],
    zip     => [ qr/[.]cbz$/, qr/[.]zip$/, ],
    pdf     => [ qw/[.]pdf$/, ],
    epub    => [ qw/[.]epub$/, ],
);
my %extract = (
    rar     => \&extract_rar,
    zip     => \&extract_zip,
    pdf     => \&extract_pdf,
    epub    => \&extract_epub,
);

my ( $destination, @sources ) = @ARGV;
# One directory used as both source and destination
if ( !@sources ) {
    push @sources, $destination;
}

find( 
    {
        wanted => sub {
            my $file = $_;
            for my $format ( keys %formats ) {
                for my $test ( @{ $formats{ $format } } ) {
                    if ( $file =~ $test ) {
                        $extract{$format}->( $File::Find::name, $destination );
                    }
                }
            }
        },
        no_chdir => 1,
    },
    @sources,
);

sub extract_rar {
    my ( $file, $destination ) = @_;
    my $cwd = getcwd;
    my $path = ( $file =~ m{^/} ? $file : abs_path( $file ) );
    chdir $destination;
    say "RAR: Extracting $path to $destination";
    capture { system 'unrar', 'e', '-ad', $path } and say "--- FAILED: $!";
    chdir $cwd;
}

sub extract_pdf {
    my ( $file, $destination ) = @_;
    my $cwd = getcwd;
    my $path = ( $file =~ m{^/} ? $file : abs_path( $file ) );
    my $dest_file = basename( $file ) . ".jpg";
    $destination = catdir( $destination, basename( $file ) );
    if ( !-d $destination ) {
        mkdir $destination;
    }
    chdir $destination;
    say "PDF: Extracting $path to $destination";
    my @limits = qw( -limit disk 90GB -limit thread 4 );
    #capture { system 'convert', '-density', 288, '-units', 'pixelsperinch', $path, '-quality', 90, '-resize', '4000x4000>', $dest_file } and say "--- FAILED: $!";
    system 'convert', @limits, '-density', 288, '-units', 'pixelsperinch', $path, '-quality', 90, '-resize', '4000x4000>', $dest_file;
    chdir $cwd;
}

sub extract_zip {
    my ( $file, $destination ) = @_;
    my $zip = Archive::Zip->new;
    $zip->read( $file );
    $destination = catdir( $destination, basename( $file ) );
    mkdir $destination if !-d $destination;
    $zip->extractTree( "", $destination . '/' );
}

sub extract_epub {
    my ( $file, $destination ) = @_;
    my $zip = Archive::Zip->new;
    $zip->read( $file );
    $destination = catdir( $destination, basename( $file ) );
    mkdir $destination if !-d $destination;
    $zip->extractTree( "", $destination, 'OPS/Image' );
    # This is kinda hacky for now. Should, in the future, look for the images
}
