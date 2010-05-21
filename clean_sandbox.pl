#!/usr/bin/perl
use strict;
use warnings;

use utf8;
use Carp;
use Getopt::Long;
use Pod::Usage;
use Config::General qw(ParseConfig);

use MediaWiki::Bot 3.0.0;

my $VERSION = '0.0.1';

=head1 NAME

clean_sandbox.pl - Cleans a wiki's sandbox

=head1 SYNOPSIS

clean_sandbox.pl --wiki=meta --summary="Cleaning the sandbox"

Options:
    --help      Opens this man page and exit
    --version   Print version information and exit
    --dry-run   Do everything but edit
    --debug     Print debug output
    --wiki      Sets which wiki to use
    --text      Sets what text to use
    --page      Sets what page to edit
    --summary   Sets an edit summary
    --username  Sets a non-default username
    --password  Request a password prompt

=head1 OPTIONS

=cut

my $help;
my $version;
my $dry_run;
my $debug;
my $wiki;
my $text;
my $page;
my $summary;
my $username;
my $password;

GetOptions(
    'help|h|?'      => \$help,
    'version|v'     => \$version,
    'dry-run'       => \$dry_run,
    'debug|verbose' => \$debug,
    'wiki=s'        => \$wiki,
    'text=s'        => \$text,
    'page=s'        => \$page,
    'summary=s'     => \$summary,
    'username=s'    => \$username,
    'password:s'    => \$password, # We can ask for it interactively!
);

=over 4

=item B<--help>, -h, -?

Opens this man page and exits.

=cut

# If they asked for help, give them a manpage generated from POD in this file. Nifty!
pod2usage(
    -verbose => 2,
) if $help;

=item B<--version>, -v

Prints the version number and exits.

=cut

if ($version) {
    require File::Basename;
    my $script = File::Basename::basename($0);
    print "$script version $VERSION\n" and exit;
}

=item B<--debug>, --verbose

Ask the script to print debugging information about what it does.

=item B<--dry-run>

Do everything except actually make the edit.

=item B<--wiki>

Sets which wiki to edit. Supply a domain name (en.wikipedia.org) or database
name (enwiki).

=item B<--text>

Overrides the default page text.

=item B<--page>

Overrides the default page to edit.

=item B<--summary>

Sets an edit summary to use instead of the default.

=item B<--username>

Use a username other than the one set in F<config/main.conf>. If you specify
--username without --password, login will be attempted by searching for cookies
for that username. Login with password will be attempted if that fails and
there is a password provided in a block for the username you provided on the
command line.

=item B<--password>

Prompt for a password to use. You I<can> put the password on the command line
directly, but you B<shouldn't!>

=cut

if (defined($password)) {
    require Term::ReadKey;

    print "[clean_sandbox.pl] password: ";
    Term::ReadKey::ReadMode('noecho');      # Don't show the password
    $password = Term::ReadKey::ReadLine(0);
    Term::ReadKey::ReadMode('restore');     # Don't bork their terminal
}

=back

=head1 DESCRIPTION

B<clean_sandbox.pl> will clean the sandbox of the given wiki.

You can override the default page to clean, text to use, and edit summary with
--page, --text, and --summary respectively. You can override the default bot
account to use with --username, and password with --password.

For security reasons, I<avoid> putting your password on the command line.
This will reveal your password to anyone on your system capable of viewing
process data. While this is safe for single-user systems, it is not on
multi-user systems. Instead, omit the password itself, and the script will
interactively prompt you for it:

    u@h:~$ perl clean_sandbox.pl --password
    [clean_sandbox.pl] password:

Non-interactive use (from cronjobs, for example) should set the password in
F<config/main.conf>.

Note that a password will only be used from F<config/main.conf> if it is in a
block for the username being used.

=head1 CAVEATS

Unlike pywikipedia's clean_sandbox.py, this script does not have an option to
repeat, and does not check how long ago the last edit was. These features may
be supported in the future; patches are welcome.

=head1 EXAMPLES

The simplest invocation uses all default values:

    perl clean_sandbox.pl

You may want to use a special edit summary:

    perl clean_sandbox.pl --summary="SANDBOT: Cleaning the sandbox"

To use a different account:

    perl clean_sandbox.pl --username="My other account" --password

=head1 FILES

The script reads F<config/clean_sandbox.conf> to get default values for page,
text, and summary. It reads F<config/main.conf> to get default values for
username, password, and wiki.

=cut

# Currently it is an error to use --username without --password. But shouldn't
# we at least attempt to log in with cookies for that username if we have any?
#die "You must use --password if you use --username" if (!$password and $username);
my $use_cookies = 1;
$use_cookies = 0 if ($username or $password);

if (!$username or !$password or !$wiki) {
    warn 'Reading config/main.conf' if $debug;
    my %main = ParseConfig (
        -ConfigFile     => 'config/main.conf',
        -LowerCaseNames => 1,
        -AutoTrue       => 1,
        -UTF8           => 1,
    );
    $username = $main{'default'} unless $username; warn "Using $username" if $debug;
    die "I can't figure out what account to use! Try setting default in config/main.conf, or use --username" unless $username;
    die "There's no block for $username and you didn't specify enough data on the command line to continue" unless $main{'bot'}{$username};

    $password = $main{'bot'}{$username}{'password'} if (!$password); warn "Setting \$password" if $debug;
    $wiki = $main{'bot'}{$username}{'wiki'} unless $wiki; warn "Setting \$wiki to $wiki" if $debug;
}

my $bot = MediaWiki::Bot->new();

my $domain;
if (!$text or !$page or !$summary) {
    warn 'Reading config/clean_sandbox.conf' if $debug;
    my %conf = ParseConfig (
        -ConfigFile     => 'config/clean_sandbox.conf',
        -LowerCaseNames => 1,
        -UTF8           => 1,
    );
    if ($wiki =~ m/\w\.\w/) {
        $domain = $wiki;
        $wiki = $bot->domain_to_db($wiki);
    }
    %conf = %{ $conf{$wiki} }; # Keep just the part we want.

    $text    = $conf{'text'} unless $text; warn "Setting \$text to $text" if $debug;
    $page    = $conf{'page'} unless $page; warn "Setting \$page to $page" if $debug;
    $summary = $conf{'summary'} unless $summary; warn "Setting \$summary to $summary" if $debug;
}

$domain = $bot->db_to_domain($wiki) if ($wiki !~ m/\w\.\w/);
warn "set_wiki($domain); # wiki: $wiki" if $debug;
$bot->set_wiki($domain);


my $logged_in = 0; # Keep track of whether we've logged in yet
if ($use_cookies) {
    $logged_in = $bot->login($username) unless $logged_in;
    warn "Logged into $username with cookies" if $debug and $logged_in;
    warn "Failed to log into $username with cookies" if $debug and !$logged_in;
}
if (!$logged_in and $password) {
    $logged_in = $bot->login($username, $password) unless $logged_in;
    warn "Logged into $username with password" if $debug and $logged_in;
    warn "Failed to log into $username with password" if $debug and !$logged_in;
}
die "Didn't log in successfully" unless $logged_in;

die <<"END" if $dry_run;
This is where we would attempt the following edit:
\$bot->edit(
    '$page',
    '$text',
    '$summary',
    1
);
END
warn "Editing..." if $debug;
$bot->edit($page, $text, $summary, 1) or die "Couldn't edit";

=head1 AUTHOR

Written by Mike.lifeguard <mike.lifeguard@gmail.com>.

=head1 COPYRIGHT

Copyright © 2010 Mike.lifeguard <mike.lifeguard@gmail.com>.

=head1 LICENSE

GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.

This is free software; you are free to change and redistribute it in accordance
with the license. There is NO WARRANTY, to the extent permitted by law.

=head1 BUGS

None known. Bug reports and feature requests should go to
L<http://bugzilla.hashbang.ca/enter_bug.cgi?product=Perlwikibot-scripts>.

=head1 TODO

=over 4

=item *
Support for secure server.

=item *
Check if the last edit is more recent than N minutes ago. If so, delay before cleaning.

=back

