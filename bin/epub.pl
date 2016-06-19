# PODNAME: epub.pl
use strict;
use warnings;

use Carp qw( confess );
use Cwd qw( abs_path );
use File::Find qw( find );
use File::Spec::Functions qw( catdir catfile );
use File::Basename qw( basename );
use File::Temp qw( tempdir );
use File::Copy qw( copy move );
use File::Copy::Recursive qw( rcopy );
use List::Util qw( sum reduce max );
use XML::LibXML;
use Imager;
use Data::UUID;
use YAML qw( LoadFile );
use Archive::Zip qw( :ERROR_CODES );
use URI::Escape qw( uri_escape );
use Getopt::Long;
use feature 'say';

my %MEDIA_TYPES = (
    jpg     => 'image/jpeg',
    jpeg    => 'image/jpeg',
    gif     => 'image/gif',
    png     => 'image/png',
);

GetOptions(
    'comic!' => \( my $comic ),
    'imagemagick|im' => \( my $imagemagick ),
    'all'    => \( my $all ),    # Do not perform outlier checks
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
            if ( -d $file ) {
                make_epub( abs_path( $file ), $destination, imagemagick => $imagemagick );
            }
        },
        no_chdir => 1,
    },
    @sources,
);

sub make_epub {
    my ( $source_dir, $destination, %opt ) = @_;
    say "EPUB: $source_dir";

    my @images = grep { is_image( $_ ) } <"$source_dir/*">;
    if ( !@images ) {
        say "-- Not an image directory: $source_dir";
        return;
    }

    # Sort the images based on how imagemagick extracts them
    if ( $opt{imagemagick} ) {
        @images = map { $_->[0] }
                  sort { $a->[1] <=> $b->[1] }
                  map { /(\d+[.]?\d*)[.]\w+$/; [ $_, $1 ] }
                  @images;
    }
    else {
        @images = sort @images;
    }

    my $dir = File::Temp->newdir;
    my $meta_dir = catdir( $dir, 'META-INF' );
    mkdir $meta_dir;
    my $ops_dir = catdir( $dir, 'OPS' );
    mkdir $ops_dir;
    my $image_dir = catdir( $ops_dir, 'Image' );
    mkdir $image_dir;
    my $page_dir = catdir( $ops_dir, 'Text' );
    mkdir $page_dir;

    write_mimetype_file( $dir );
    write_container_file( $meta_dir );

    my $metadata = {};
    if ( -f catfile( $source_dir, 'metadata.yml' ) ) {
        $metadata = LoadFile( catfile( $source_dir, 'metadata.yml' ) );
    }
    else {
        warn "No metadata file found in $source_dir\n";
    }

    my ( $add_blank, $width, $height );
    my @plan;
    # In comic mode, try to find double-wide pages and rotated pages
    # We might also have some images that are not part of the book mixed in
    if ( $comic ) {
        # First find the most likely candidate for the height/width of the book
        my @sizes;
        for my $img ( @images ) {
            my $imager = Imager->new( file => $img );
            if ( !$imager ) {
                warn "Could not create imager: " . Imager->errstr;
                next;
            }
            push @plan, {
                file        => $img,
                width       => $imager->getwidth,
                height      => $imager->getheight,
                ratio       => ( $imager->getwidth / $imager->getheight ),
            };
        }
        my $plan_width = sub {
            my ( $plan ) = @_;
            return $plan->{plan_width} || ( $plan->{ratio} < 1 ? $plan->{width} : $plan->{height} );
        };
        my $plan_height = sub {
            my ( $plan ) = @_;
            return $plan->{plan_height} || ( $plan->{ratio} < 1 ? $plan->{height} : $plan->{width} );
        };
        my $plan_ratio = sub {
            my ( $plan ) = @_;
            return $plan->{plan_ratio} || ( $plan->{ratio} < 1 ? $plan->{ratio} : 1/$plan->{ratio} );
        };
        my ( $avg_width, $avg_height, $avg_ratio, $stddev_width, $stddev_height, $stddev_ratio );

        my $calculate_plan = sub {
            $avg_width = $width = sum( map { $plan_width->( $_ ) } @plan ) / @plan;
            $avg_height = $height = sum( map { $plan_height->( $_ ) } @plan ) / @plan;
            $avg_ratio = sum( map { $plan_ratio->( $_ ) } @plan ) / @plan;
            $stddev_width = sqrt( sum( map { ( $plan_width->($_) - $avg_width ) ** 2 } @plan ) / @plan );
            $stddev_height = sqrt( sum( map { ( $plan_height->( $_ ) - $avg_height ) ** 2 } @plan ) / @plan );
            $stddev_ratio = sqrt( sum( map { ( $plan_ratio->( $_ ) - $avg_ratio ) ** 2 } @plan ) / @plan );
        };
        $calculate_plan->(); # Start with some shitty numbers

        # Remove outliers and recalculate the averages
        my $count = 0;
        my $i = 0;
        while ( $i <= $#plan ) {
            my $p = $plan[$i];
            my $width = $plan_width->( $p );
            my $height = $plan_height->( $p );
            my $ratio = $plan_ratio->( $p );

            # - Rotated: Ratio > 1 and reciprocal of ratio within 2stddev of average ratio
            if ( $ratio > 1 && near( 1/$ratio, $avg_ratio, 2*$stddev_ratio ) ) {
                $p->{rotate} = 1;
                $width = $p->{plan_width} = $p->{height};
                $height = $p->{plan_height} = $p->{width};
                $ratio = $p->{plan_ratio} = $p->{plan_width} / $p->{plan_height};
            }
            # - Double: Height within 2stddev of avg_height, Width / 2 within 2stddev of avg_width
            elsif ( near( $p->{width} / 2 / $p->{height}, $avg_ratio, 2*$stddev_ratio ) ) {
                $p->{double} = 1;
                $width = $p->{plan_width} = $p->{width} / 2;
                $height = $p->{plan_height} = $p->{height};
                $ratio = $p->{plan_ratio} = $p->{plan_width} / $p->{plan_height};
            }
            # - Double: Height * 2 within 2stddev of avg_height, Width within 2stddev of avg_width
            elsif ( near( $p->{width} / ( $p->{height} * 2 ), $avg_ratio, 2*$stddev_ratio ) ) {
                $p->{double} = 1;
                $width = $p->{plan_width} = $p->{width};
                $height = $p->{plan_height} = $p->{height} * 2;
                $ratio = $p->{plan_ratio} = $p->{plan_width} / $p->{plan_height};
            }
            # - Double+Rotated: Width within 2stddev of avg_height, Height / 2 within 2stddev of avg_width
            elsif ( near( $p->{height} / 2 / $p->{width}, $avg_ratio, 2*$stddev_ratio ) ) {
                $p->{double} = 1;
                $p->{rotate} = 1;
                $width = $p->{plan_width} = $p->{height} / 2;
                $height = $p->{plan_height} = $p->{width};
                $ratio = $p->{plan_ratio} = $p->{plan_width} / $p->{plan_height};
            }
            # - Double+Rotated: Width * 2 within 2stddev of avg_height, Height within 2stddev of avg_width
            elsif ( near( $p->{height} / ( $p->{width} * 2 ), $avg_ratio, 2*$stddev_ratio ) ) {
                $p->{double} = 1;
                $p->{rotate} = 1;
                $width = $p->{plan_width} = $p->{height};
                $height = $p->{plan_height} = $p->{width} * 2;
                $ratio = $p->{plan_ratio} = $p->{plan_width} / $p->{plan_height};
            }
            $calculate_plan->();

            # Determine if it is an outlier
            # Only ratio appears anywhere near accurate...
            if ( !$all && !near( $ratio, $avg_ratio, 4*$stddev_ratio ) ) {
                my $file = basename( $p->{file} );
                warn "  Outlier (ratio)  $file\n    (w: $p->{width}, h: $p->{height}, r: $p->{ratio})\n    Calc (w: $width, h: $height, r: $ratio)\n    Avg (w: $avg_width, h: $avg_height, r: $avg_ratio )\n    Stddev (w: $stddev_width, h: $stddev_height, r: $stddev_ratio )\n";
                splice @plan, $i, 1;
                $calculate_plan->();
                next;
            }

            # Passes our checks, we're adding this page
            my $file = basename( $p->{file} );
            if ( $p->{rotate} && $p->{double} ) {
                warn "  Doubled+Rotated  $file\n    (w: $p->{width}, h: $p->{height}, r: $p->{ratio})\n    Calc (w: $width, h: $height, r: $ratio)\n    Avg (w: $avg_width, h: $avg_height, r: $avg_ratio )\n    Stddev (w: $stddev_width, h: $stddev_height, r: $stddev_ratio )\n";
            }
            elsif ( $p->{rotate} ) {
                warn "  Rotated          $file\n    (w: $p->{width}, h: $p->{height}, r: $p->{ratio})\n    Calc (w: $width, h: $height, r: $ratio)\n    Avg (w: $avg_width, h: $avg_height, r: $avg_ratio )\n    Stddev (w: $stddev_width, h: $stddev_height, r: $stddev_ratio )\n";
            }
            elsif ( $p->{double} ) {
                warn "  Doubled          $file\n    (w: $p->{width}, h: $p->{height}, r: $p->{ratio})\n    Calc (w: $width, h: $height, r: $ratio)\n    Avg (w: $avg_width, h: $avg_height, r: $avg_ratio )\n    Stddev (w: $stddev_width, h: $stddev_height, r: $stddev_ratio )\n";
            }
            if ( $p->{double} ) {
                # Do we need to add a blank page after the cover?
                # Odd pages are on the left, even pages are on the right
                # If the double page starts on the right, add one just after the cover
                # Do not add a blank if we have a wraparound cover
                if ( $count > 0 && $count % 2 == 0 ) {
                    $add_blank = 1;
                    warn "  Double page offset, need to add a blank page\n";
                    $count++; # We just added a page right after the cover
                }
                $count++; # Extra counter, we added two pages
            }
            $count++;
            $i++;
        }

        # Plan is done, we know our size
        $width = sum( map { $_->{plan_width} || $_->{width} } @plan ) / @plan;
        $height = sum( map { $_->{plan_height} || $_->{height} } @plan ) / @plan;
    }


    my $count = 0;
    my %images;
    my %pages;
    my $back_cover_image_id;
    for my $plan ( @plan ) {
        my $image = $plan->{file};
        my $imager = Imager->new( file => $image );
        my $image_id = sprintf 'image-%04d', $count;
        if ( $comic && $plan->{rotate} ) {
            my $rotated = $imager->rotate( degrees => 270 );
            $rotated->write( file => catfile( $image_dir, basename( $image ) ) );
        }
        else {
            copy( $image, $image_dir );
        }
        # Rename the cover "cover"
        if ( $count == 0 ) {
            my ( $ext ) = basename( $image ) =~ m{[.](\w+)$};
            my $newname = "cover.$ext";
            move( catfile( $image_dir, basename( $image ) ), catfile( $image_dir, $newname ) );
            $image = catfile( $image_dir, $newname );
        }
        my $image_src = catfile( 'Image', uri_escape( basename( $image ) ) );
        $images{ $image_id } = {
            'media-type' => get_media_type( $image_src ),
            href => $image_src,
            imager => $imager,
        };

        # Add a blank page right after the cover
        if ( $comic && $add_blank && $count == 1 ) {
            my $page_id = sprintf 'page-%04d', $count;
            my $page_file = catfile( $page_dir, $page_id . '.xhtml' );
            add_blank_page( $page_id, $page_file,
                viewport => {
                    width => $width || $imager->getwidth,
                    height => $height || $imager->getheight,
                },
            );
            $pages{ $page_id } = {
                'media-type' => 'application/xhtml+xml',
                href => catfile( 'Text', "$page_id.xhtml" ),
            };
            $count++;
        }

        # In comic mode, turn double-wide pages into two pages
        if ( $comic && $plan->{double} ) {
            if ( $count == 0 ) {
                # Wrap-around cover
                $back_cover_image_id = $image_id;
                my $page_id = sprintf 'page-%04d', $count;
                my $page_file = catfile( $page_dir, $page_id . '.xhtml' );
                add_right_page( $page_id, catfile( '..', $image_src ), $page_file,
                    viewport => {
                        width => $width || int( $imager->getwidth / 2 ),
                        height => $height || $imager->getheight,
                    },
                );
                $pages{ $page_id } = {
                    'media-type' => 'application/xhtml+xml',
                    href => catfile( 'Text', "$page_id.xhtml" ),
                };
                $count++;
            }
            else {
                # Regular double-wide page
                my $page_id = sprintf 'page-%04d', $count;
                my $page_file = catfile( $page_dir, $page_id . '.xhtml' );
                add_left_page( $page_id, catfile( '..', $image_src ), $page_file,
                    viewport => {
                        width => $width || int( $imager->getwidth / 2 ),
                        height => $height || $imager->getheight,
                    },
                );
                $pages{ $page_id } = {
                    'media-type' => 'application/xhtml+xml',
                    href => catfile( 'Text', "$page_id.xhtml" ),
                };
                $count++;
                $page_id = sprintf 'page-%04d', $count;
                $page_file = catfile( $page_dir, $page_id . '.xhtml' );
                add_right_page( $page_id, catfile( '..', $image_src ), $page_file,
                    viewport => {
                        width => $width || int( $imager->getwidth / 2 ),
                        height => $height || $imager->getheight,
                    },
                );
                $pages{ $page_id } = {
                    'media-type' => 'application/xhtml+xml',
                    href => catfile( 'Text', "$page_id.xhtml" ),
                };
                $count++;
            }
        }
        else {
            my $page_id = sprintf 'page-%04d', $count;
            my $page_file = catfile( $page_dir, $page_id . '.xhtml' );
            add_page( $page_id, catfile( '..', $image_src ), $page_file,
                viewport => {
                    width => $width || $imager->getwidth,
                    height => $height || $imager->getheight,
                },
            );
            $pages{ $page_id } = {
                'media-type' => 'application/xhtml+xml',
                href => catfile( 'Text', "$page_id.xhtml" ),
            };
            $count++;
        }
    }

    # Did we have a wrap-around cover?
    if ( $back_cover_image_id ) {
        my $image = $images{ $back_cover_image_id };
        my $image_src = $image->{href};
        my $imager = $image->{imager};
        my $page_id = sprintf 'page-%04d', $count;
        my $page_file = catfile( $page_dir, $page_id . '.xhtml' );
        add_left_page( $page_id, catfile( '..', $image_src ), $page_file,
            viewport => {
                width => $width || int( $imager->getwidth / 2 ),
                height => $height || $imager->getheight,
            },
        );
        $pages{ $page_id } = {
            'media-type' => 'application/xhtml+xml',
            href => catfile( 'Text', "$page_id.xhtml" ),
        };
        $count++;
    }

    my $nav_file = catfile( $page_dir, 'nav.xhtml' );
    write_nav_file( $nav_file, \%pages );
    write_package_file(
        $ops_dir,
        images => \%images,
        pages => \%pages,
        nav => catfile( 'Text', 'nav.xhtml' ),
        metadata => $metadata,
    );

    my $title = $metadata->{title} || basename( $source_dir );
    # Slashes are not welcome
    $title =~ tr{/}{-};
    write_zip_file( $dir, catfile( $destination, $title . '.epub' ) );
}

sub write_mimetype_file {
    my ( $dir ) = @_;
    open my $fh, '>', catfile( $dir, 'mimetype' ) or die "Could not write mimetype file: $!\n";
    print { $fh } 'application/epub+zip';
}

sub write_container_file {
    my ( $meta_dir ) = @_;
    open my $fh, '>', catfile( $meta_dir, 'container.xml' ) or die "Could not write container file: $!\n";
    print { $fh } <<ENDXML;
<?xml version="1.0" encoding="UTF-8"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
<rootfiles>
<rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
</rootfiles>
</container>
ENDXML

    open $fh, '>', catfile( $meta_dir, 'com.apple.ibooks.display-options.xml' ) or die "Could not write itunes meta file: $!\n";
    print { $fh } <<ENDXML;
<?xml version="1.0" encoding="UTF-8"?>
<display_options>
  <platform name="*">
     <option name="fixed-layout">true</option>
     <option name="open-to-spread">false</option>
  </platform>
</display_options>
ENDXML
}

sub write_nav_file {
    my ( $nav_file, $pages ) = @_;
    my $xml = XML::LibXML::Document->createDocument( '1.0', 'utf-8' );
    my $doc = $xml->createElement('html');
    $doc->setAttribute( 'xmlns' => "http://www.w3.org/1999/xhtml" );
    $doc->setAttribute( 'xmlns:epub' => "http://www.idpf.org/2007/ops" );
    $xml->setDocumentElement( $doc );

    my $head_node = $xml->createElement( 'head' );
    $doc->appendChild( $head_node );
    my $title_node = $xml->createElement( 'title' );
    $title_node->appendChild( $xml->createTextNode( 'Table of Contents' ) );
    $head_node->appendChild( $title_node );

    my $body_node = $xml->createElement( 'body' );
    $doc->appendChild( $body_node );

    my $page_div = $xml->createElement( 'section' );
    $page_div->setAttribute( 'epub:type' => 'frontmatter toc' );
    $body_node->appendChild( $page_div );

    my $nav_node = $xml->createElement( 'nav' );
    $nav_node->setAttribute( 'epub:type' => 'toc' );
    $nav_node->setAttribute( id => 'toc' );
    $page_div->appendChild( $nav_node );

    my $ol_node = $xml->createElement( 'ol' );
    $nav_node->appendChild( $ol_node );

    my $count = 0;
    for my $key ( sort keys %$pages ) {
        my $li_node = $xml->createElement( 'li' );
        my $a_node = $xml->createElement( 'a' );

        $a_node->setAttribute( href => basename( $pages->{$key}{href} ) );
        $a_node->appendChild( $xml->createTextNode( ++$count ) );

        $li_node->appendChild( $a_node );
        $ol_node->appendChild( $li_node );
    }

    $xml->toFile( $nav_file );
}

sub write_package_file {
    my ( $dir, %opt ) = @_;

    my $xml = XML::LibXML::Document->createDocument( '1.0', 'utf-8' );
    my $doc = $xml->createElement('package');
    $doc->setAttribute( 'xmlns' => "http://www.idpf.org/2007/opf" );
    $doc->setAttribute( version => '3.0' );
    $xml->setDocumentElement( $doc );

    my $metadata_node = $xml->createElement( 'metadata' );
    $metadata_node->setAttribute( 'xmlns:dc' => 'http://purl.org/dc/elements/1.1/' );
    $metadata_node->setAttribute( 'xmlns:opf' => 'http://www.idpf.org/2007/opf' );
    $doc->appendChild( $metadata_node );
    my %meta = qw(
        rendition:layout        pre-paginated
        rendition:orientation   auto
        rendition:spread        auto
        cover                   cover
    );
    for my $key ( keys %meta ) {
        my $node = $xml->createElement( 'meta' );
        $node->setAttribute( property => $key );
        $node->appendChild( $xml->createTextNode( $meta{$key} ) );
        $metadata_node->appendChild( $node );
    }

    my $id = Data::UUID->new->create_str;
    my $id_node = $xml->createElement( 'dc:identifier' );
    $id_node->setAttribute( id => 'pub-id' );
    $id_node->appendChild( $xml->createTextNode(
        'urn:uuid:' . $id
    ) );
    $metadata_node->appendChild( $id_node );

    # Add metadata from YAML file
    if ( $opt{metadata} ) {
        if ( $opt{metadata}{title} ) {
            my $node = $xml->createElement( 'dc:title' );
            $node->appendChild( $xml->createTextNode( $opt{metadata}{title} ) );
            $metadata_node->appendChild( $node );
        }
        if ( $opt{metadata}{author} ) {
            my $node = $xml->createElement( 'dc:creator' );
            if ( $opt{metadata}{sort}{author} ) {
                $node->setAttribute( 'opf:file-as' => $opt{metadata}{sort}{author} );
            }
            $node->setAttribute( 'opf:role' => 'aut' );
            $node->appendChild( $xml->createTextNode( $opt{metadata}{author} ) );
            $metadata_node->appendChild( $node );
        }
        if ( $opt{metadata}{publisher} ) {
            my $node = $xml->createElement( 'dc:publisher' );
            $node->appendChild( $xml->createTextNode( $opt{metadata}{publisher} ) );
            $metadata_node->appendChild( $node );
        }
        if ( $opt{metadata}{genre} ) {
            my $node = $xml->createElement( 'dc:subject' );
            $node->appendChild( $xml->createTextNode( $opt{metadata}{genre} ) );
            $metadata_node->appendChild( $node );
        }
        if ( $opt{metadata}{isbn} ) {
            my $node = $xml->createElement( 'dc:identifier' );
            $node->setAttribute( 'opf:scheme' => 'ISBN' );
            $node->appendChild( $xml->createTextNode( $opt{metadata}{isbn} ) );
            $metadata_node->appendChild( $node );
        }
    }

    my $manifest_node = $xml->createElement( 'manifest' );
    $doc->appendChild( $manifest_node );
    my $spine_node = $xml->createElement( 'spine' );
    $doc->appendChild( $spine_node );

    my $first = 1;
    for my $key ( sort keys %{ $opt{images} } ) {
        my $item = $xml->createElement( 'item' );
        if ( $first-- ) {
            $item->setAttribute( properties => 'cover-image' );
            $item->setAttribute( id => 'cover' );
        }
        else {
            $item->setAttribute( id => $key );
        }
        $item->setAttribute( href => $opt{images}{$key}{href} );
        $item->setAttribute( 'media-type' => $opt{images}{$key}{'media-type'} );
        $manifest_node->appendChild( $item );
    }

    my $nav_node = $xml->createElement( 'item' );
    $nav_node->setAttribute( id => 'nav' );
    $nav_node->setAttribute( href => $opt{nav} );
    $nav_node->setAttribute( properties => 'nav' );
    $nav_node->setAttribute( 'media-type' => 'application/xhtml+xml' );
    $manifest_node->appendChild( $nav_node );

    for my $key ( sort keys %{ $opt{pages} } ) {
        my $item = $xml->createElement( 'item' );
        $item->setAttribute( id => $key );
        $item->setAttribute( href => $opt{pages}{$key}{href} );
        $item->setAttribute( 'media-type' => $opt{pages}{$key}{'media-type'} );
        $manifest_node->appendChild( $item );

        my $itemref = $xml->createElement( 'itemref' );
        $itemref->setAttribute( idref => $key );
        $spine_node->appendChild( $itemref );
    }

    $xml->toFile( catfile( $dir, 'package.opf' ) );
}

sub write_zip_file {
    my ( $source, $destination ) = @_;
    my $zip = Archive::Zip->new;
    $zip->addTree( $source, '' );
    $zip->writeToFileNamed( $destination );
}

sub start_page {
    my ( %opt ) = @_;
    my $xml = XML::LibXML::Document->createDocument( '1.0', 'utf-8' );
    my $doc = $xml->createElement('html');
    $doc->setAttribute( 'xmlns' => "http://www.w3.org/1999/xhtml" );
    $doc->setAttribute( 'xmlns:epub' => "http://www.idpf.org/2007/ops" );
    $xml->setDocumentElement( $doc );

    my $head_node = $xml->createElement( 'head' );
    $doc->appendChild( $head_node );
    if ( $opt{title} ) {
        my $title_node = $xml->createElement( 'title' );
        $title_node->appendChild( $xml->createTextNode( $opt{title} ) );
        $head_node->appendChild( $title_node );
    }
    if ( $opt{viewport} ) {
        my $meta_node = $xml->createElement( 'meta' );
        $meta_node->setAttribute( name => 'viewport' );
        $meta_node->setAttribute(
            content => sprintf( 'width=%d, height=%d', $opt{viewport}{width}, $opt{viewport}{height} ),
        );
        $head_node->appendChild( $meta_node );
        my $style_node = $xml->createElement( 'style' );
        $style_node->setAttribute( type => 'text/css' );
        $style_node->appendChild( $xml->createTextNode( <<"ENDCSS" ) );
* { margin: 0; padding: 0; }
body {
    width: $opt{viewport}{width}px;
    height: $opt{viewport}{height}px;
}
img {
    height: $opt{viewport}{height}px;
}
ENDCSS
        $head_node->appendChild( $style_node );
    }

    my $body_node = $xml->createElement( 'body' );
    $doc->appendChild( $body_node );
    return ( $xml, $body_node );
}

sub add_page {
    my ( $page_id, $image_src, $page_file, %opt ) = @_;
    my ( $xml, $body_node ) = start_page( %opt );
    my $page_div = $xml->createElement( 'div' );
    $body_node->appendChild( $page_div );
    my $img_node = $xml->createElement( 'img' );
    $img_node->setAttribute( src => $image_src );
    $page_div->appendChild( $img_node );

    $xml->toFile( $page_file );
}

sub add_left_page {
    my ( $page_id, $image_src, $page_file, %opt ) = @_;
    my ( $xml, $body_node ) = start_page( %opt );
    my $page_div = $xml->createElement( 'div' );
    $page_div->setAttribute( style => 'position: relative; width: 100%; height: 100%; overflow: hidden' );
    $body_node->appendChild( $page_div );
    my $img_node = $xml->createElement( 'img' );
    $img_node->setAttribute( src => $image_src );
    $img_node->setAttribute( style => 'position: absolute; left: 0' );
    $page_div->appendChild( $img_node );

    $xml->toFile( $page_file );
}

sub add_right_page {
    my ( $page_id, $image_src, $page_file, %opt ) = @_;
    my ( $xml, $body_node ) = start_page( %opt );
    my $page_div = $xml->createElement( 'div' );
    $page_div->setAttribute( style => 'position: relative; width: 100%; height: 100%; overflow: hidden' );
    $body_node->appendChild( $page_div );
    my $img_node = $xml->createElement( 'img' );
    $img_node->setAttribute( src => $image_src );
    $img_node->setAttribute( style => 'position: absolute; right: 0' );
    $page_div->appendChild( $img_node );

    $xml->toFile( $page_file );
}

sub add_blank_page {
    my ( $page_id, $page_file, %opt ) = @_;
    my ( $xml, $body_node ) = start_page( %opt );
    $xml->toFile( $page_file );
}

sub is_image {
    my ( $file ) = @_;
    return 1 if $file =~ /[.](?:jpe?g|png|gif)$/i;
    return 0;
}

sub get_media_type {
    my ( $image ) = @_;
    $image =~ m{[.](jpe?g|png|gif)$}i;
    my $type = lc $1;
    if ( !$MEDIA_TYPES{ $type } ) {
        confess "Unknown media type: $type\n";
    }
    return $MEDIA_TYPES{ $type };
}

sub near {
    my ( $val, $test, $tolerance ) = @_;
    return $val == $test # Quick short-circuit
        || ( $val > $test - $tolerance && $val < $test + $tolerance );
}
