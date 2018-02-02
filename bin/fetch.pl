
use v5.24;
use warnings;
use open ':encoding(utf8)';
use FindBin qw( $Bin );
use Mojo::UserAgent;
use Net::Address::IP::Local;
use Mojo::Cookie::Response;
use Mojo::File qw( path );
use YAML;
use List::Util qw( minstr );

my $UAID = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_4) AppleWebKit/603.1.30 (KHTML, like Gecko) Version/10.1 Safari/603.1.30';
my $state_file = path( $Bin )->sibling( var => 'fetch-state.yml' );
my $state = -f $state_file ? YAML::LoadFile( "$state_file" ) : {};
my $host = 'https://www.torrentleech.org';
my $root = $host . '/torrents/browse/index/page/';
my $cookies_file = path( $Bin )->sibling( var => 'fetch-cookies.yml' );
my $torrents_dir = path( $Bin )->sibling( var => 'torrent' );
my $rules_file = path( $Bin )->sibling( etc => 'rules.yml' );
my @rules = -f $rules_file ? YAML::LoadFile( "$rules_file" ) : ();
my $torrent_server = "sadie.local:~/Downloads";

my $start_page = 1;
my $max_page = 50;

my $ua = Mojo::UserAgent->new(
    # Force Mojolicious to use IPv4
    local_address => Net::Address::IP::Local->public_ipv4,
);
$ua->transactor->name( $UAID );

if ( -f $cookies_file ) {
    say STDERR "-- Using saved session cookies...";
    my @cookies = YAML::LoadFile( "$cookies_file" );
    $ua->cookie_jar->add( @cookies );
}
else {
    say STDERR "-- Logging in...";
    login( $ua );
}

my $first_id;
my @found_items;

PAGE:
for my $page ( $start_page .. $max_page ) {
    my $tx = $ua->get( $root . $page );
    my $tbody = $tx->res->dom->at( '#torrenttable tbody' );

    if ( !$tbody ) {
        use Data::Dumper;
        warn "Could not find table body: " . $tx->res->body . " (" . Dumper( $tx->res->error ) . ")";
        if ( $tx->res->dom->at( '[action="/user/account/login/"]' ) ) {
            say "Found login form, logging in...";
            login( $ua );
            redo;
        }
        else {
            die "No table body and no login form found";
        }
    }

    ROW:
    for my $row ( $tbody->find( 'tr' )->each ) {
        my $id = $row->attr( 'id' );

        if ( !$first_id ) {
            $first_id = $id;
        }
        if ( $id <= $state->{last_id} ) {
            last PAGE;
        }

        my $title = $row->at( 'td.name .title' )->all_text;
        my $url = $row->at( 'td.quickdownload a' )->attr( 'href' );

        unshift @found_items, { id => $id, title => $title, url => $url };
    }
}

for my $item ( @found_items ) {
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
        say "\tCopying to Sadie...";
        my $exit = system( "scp", "$dest", $torrent_server );
        if ( $exit ) {
            say "\tUnable to copy to sadie";
        }
    }
    else {
        say "\tSkipping...";
    }

    say "";
}

$state->{last_id} = $first_id;
YAML::DumpFile( "$state_file", $state );

sub login {
    my $tx = $ua->post( $host . '/user/account/login/', form => { username => 'preaction', password => '26220b0b%' } );
    my $cookies = $ua->cookie_jar->all;
    YAML::DumpFile( $cookies_file, @$cookies );
}
