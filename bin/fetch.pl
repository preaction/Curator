
use v5.24;
use warnings;
use open ':encoding(utf8)';
use FindBin qw( $Bin );
use Mojo::UserAgent;
use Net::Address::IP::Local;
use Mojo::URL;
use Mojo::File qw( path );
use YAML;
use List::Util qw( minstr );

my $UAID = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/11.1 Safari/605.1.15';
my $state_file = path( $Bin )->sibling( var => 'fetch-state.yml' );
my $state = -f $state_file ? YAML::LoadFile( "$state_file" ) : {};
my $config_file = path( $Bin )->sibling( etc => 'fetch.yml' );
my $config = YAML::LoadFile( "$config_file" );
my $url = $config->{url};
my $torrents_dir = path( $Bin )->sibling( var => 'torrent' );
my $rules_file = path( $Bin )->sibling( etc => 'rules.yml' );
my @rules = -f $rules_file ? YAML::LoadFile( "$rules_file" ) : ();
my $torrent_server = "old-mini.local:~/Downloads";

my $ua = Mojo::UserAgent->new(
    # Force Mojolicious to use IPv4
    local_address => Net::Address::IP::Local->public_ipv4,
);
$ua->transactor->name( $UAID );

my $first_id;
my @found_items;

my $tx = $ua->get( $url );
for my $item ( $tx->res->dom->find( 'channel > item' )->each ) {
    my $guid = Mojo::URL->new( $item->at( 'guid' )->text );
    my $id = $guid->path->[-1];

    if ( !$first_id ) {
        $first_id = $id;
    }
    if ( $id <= $state->{last_id} ) {
        last;
    }

    my $title = $item->at( 'title' )->text;
    my $url = $item->at( 'link' )->text;

    push @found_items, { id => $id, title => $title, url => $url };
}

for my $item ( reverse @found_items ) {
    my ( $id, $title, $url ) = @{ $item }{qw( id title url )};
    say "[$id] $title\n\t$url";

    my $want = 0;
    RULE:
    for my $rule ( @rules ) {
        next unless $rule->{match};
        next unless $title =~ /$rule->{match}/;
        next if $rule->{except} && $title =~ /$rule->{except}/;

        if ( $title =~ /(DUBBED|HARDSUB|HC|SUBPACK)/i ) {
            say "\tSkipping because: $1";
            next;
        }

        # TV episodes should be compared against the list of
        # gotten episodes
        if ( $rule->{episodes} ) {
            my ( $ep ) = $title =~ /\b(S\d{2}E\d{2})\b/;
            if ( !$ep ) {
                say "\tExpected S--E-- but couldn't find it";
                next;
            }

            my $first_ep = minstr keys $state->{episodes}{ $rule->{name} }->%*;
            if ( $ep lt $first_ep ) {
                say "\tEpisode older than first episode downloaded ($first_ep). Skipping.";
                next;
            }
            elsif ( !$state->{episodes}{ $rule->{name} }{ $ep } ) {
                say "\tEpisode not downloaded yet";
                $state->{episodes}{ $rule->{name} }{ $ep } = {
                    id => $id,
                    title => $title,
                    url => $url,
                };
                $want = 1;
            }
            elsif ( $title =~ /(REAL|PROPER|REPACK)/ ) {
                say "\tEpisode already downloaded, but this is $1";
                $state->{episodes}{ $rule->{name} }{ "$ep-$1" } = {
                    id => $id,
                    title => $title,
                    url => $url,
                };
                $want = 1;
            }
            else {
                say "\tEpisode already downloaded";
            }
        }
        else {
            if ( !$state->{matched}{ $rule->{name} } ) {
                say "\tNot matched";
                $state->{matched}{ $rule->{name} } = {
                    id => $id,
                    title => $title,
                    url => $url,
                };
                $want = 1;
            }
            else {
                my $match = $state->{matched}{ $rule->{name} };
                say "\tRule already matched: [$match->{id}] $match->{title}";
            }
        }

        last RULE;
    }

    if ( $want ) {
        say "\tDownloading...";
        my $tx = $ua->get( $url );
        my $name = $tx->req->url->path->parts->[-1];
        my $dest = $torrents_dir->child( $name );
        $tx->result->content->asset->move_to( $dest );
        say "\tCopying to old-mini...";
        my $exit = system( "scp", "$dest", $torrent_server );
        if ( $exit ) {
            say "\tUnable to copy to old-mini";
        }
    }
    else {
        say "\tSkipping...";
    }

    say "";
}

$state->{last_id} = $first_id;
YAML::DumpFile( "$state_file", $state );

