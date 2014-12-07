
use strict;
use warnings;
use feature qw( say );

use Cwd qw( getcwd abs_path chdir );
use File::Basename qw( basename );
use File::Find;
use Path::Tiny;
use IO::CaptureOutput qw( capture );
use Archive::Rar; # Fuck this module... Make a better one...
use Archive::Zip; # Fuck this module only slightly less...

$|++;

my %spam = (
    nfo => sub {
        my ( $file ) = @_;
        return 1 if $file =~ /[.]nfo$/;
        return;
    },
    diz => sub {
        my ( $file ) = @_;
        return 1 if $file =~ /[.]diz$/;
        return;
    },
);

my %any_archive = (
    rar => {
        main => sub {
            my ( $file ) = @_;
            return 1 if $file =~ /[.]cbr$/;
            return 1 if $file =~ /[.]part0*1[.]rar$/;
            return 1 if $file =~ /[.]rar$/ && $file !~ /[.]part\d+[.]rar$/;
            return;
        },

        any => sub {
            my ( $file ) = @_;
            return 1 if $file =~ /[.]r\d{2}$/;
            # .part\d*.rar and .rar
            return 1 if $file =~ /[.]rar$/;
            return;
        },
    },

    zip => {
        main => sub {
            my ( $file ) = @_;
            return 1 if $file =~ /[.]cbz$/;
            return 1 if $file =~ /[.]zip$/;
            return;
        },
    },
);

my %formats = (
    rar     => $any_archive{rar}{main},
    zip     => $any_archive{zip}{main},
    pdf     => sub {
        my ( $file ) = @_;
        return 1 if $file =~ /[.]pdf$/;
        return;
    },
    epub    => sub {
        my ( $file ) = @_;
        return 1 if $file =~ /[.]epub$/;
        return;
    },
);
my %extract = (
    rar     => \&extract_rar,
    zip     => \&extract_zip,
    pdf     => \&extract_pdf,
    epub    => \&extract_epub,
);

my %list = (
    rar     => \&list_rar,
    zip     => \&list_zip,
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
                if ( $formats{ $format }->( $file ) ) {
                    my $rel_path = find_rel_dir( $File::Find::dir );
                    my $archive = $File::Find::name;

                    say $archive;
                    say $format;
                    say $list{ $format };
                    # Figure out the destination
                    say "rel_path: $rel_path";
                    say "destination: $destination";
                    my @path_parts = ( $destination );
                    push @path_parts, $rel_path if $rel_path;
                    my $ex_dest = path( @path_parts );

                    if ( $list{ $format } ) {
                        say "HELLO";

                        my @files;
                        for my $file ( $list{ $format }->( $archive ) ) {
                            push @files, $file unless grep { $_->( $file ) } values %spam;
                        }

                        # If we only have one file inside, don't make all the
                        # directories
                        say "File: $_" for @files;
                        if ( @files == 1 && $rel_path ) {
                            say "ONLY ONE FILE";
                            #$ex_dest = $ex_dest->parent;
                        }

                        # If there is an archive inside, only extract the archive
                        # and in the parent directory
                        # ... and then wait to extract this archive too. We have to wait
                        # because it may have multiple parts
                        # XXX TODO

                    }

                    say $ex_dest;
                    #return;
                    $extract{$format}->( $archive, $ex_dest );
                }
            }
        },
        no_chdir => 1,
    },
    @sources,
);

sub find_rel_dir {
    my ( $path ) = @_;
    for my $dir ( @sources ) {
        if ( $path =~ /^\Q$dir/ ) {
            $path =~ s/\Q$dir//;
            return $path;
        }
    }
}

sub list_rar {
    my ( $file ) = @_;
    # This. Sucks. So. Much.
    my $output = `unrar vt "$file"`;
    my @files = $output =~ /^\s*Name: (.+)$/mg;
    return @files;
}

sub list_zip {
    my ( $file ) = @_;
    my $zip = Archive::Zip->new;
    $zip->read( $file );
    return $zip->memberNames;
}

sub extract_rar {
    my ( $file, $destination ) = @_;
    my $cwd = getcwd;
    my $path = ( $file =~ m{^/} ? $file : abs_path( $file ) );
    system 'mkdir', '-p', $destination;
    chdir $destination;
    say "RAR: Extracting $path to $destination";
    capture { system 'unrar', 'e', $path } and say "--- FAILED: $!";
    chdir $cwd;
}

sub extract_pdf {
    my ( $file, $destination ) = @_;
    my $cwd = getcwd;
    my $path = ( $file =~ m{^/} ? $file : abs_path( $file ) );
    my $dest_file = basename( $file ) . ".jpg";
    $destination = path( $destination, basename( $file ) );
    system 'mkdir', '-p', $destination;
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
    system 'mkdir', '-p', $destination;
    $zip->extractTree( "", $destination . '/' );
}

sub extract_epub {
    my ( $file, $destination ) = @_;
    my $zip = Archive::Zip->new;
    $zip->read( $file );
    $destination = path( $destination, basename( $file ) );
    system 'mkdir', '-p', $destination;
    $zip->extractTree( "", $destination, 'OPS/Image' );
    # This is kinda hacky for now. Should, in the future, look for the images
}
