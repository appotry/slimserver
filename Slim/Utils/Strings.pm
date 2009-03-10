package Slim::Utils::Strings;

# $Id$

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

=head1 NAME

Slim::Utils::Strings

=head1 SYNOPSIS

init ()

loadStrings ( [ $argshash ] )

string ( $token )

getString ( $token )

stringExists ( $token )

setString ( $token, $string )

=head1 DESCRIPTION

Global localization module.  Handles the reading of strings.txt for international translations

=head1 EXPORTS

string()

=cut

use strict;
use Exporter::Lite;

our @EXPORT_OK = qw(string cstring clientString);

use POSIX qw(setlocale LC_TIME);
use File::Spec::Functions qw(:ALL);
use Scalar::Util qw(blessed);
use Storable;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;

our $strings = {};
our $defaultStrings;

our $currentLang;
my $failsafeLang  = 'EN';

my $log = logger('server');

my $prefs = preferences('server');

=head1 METHODS

=head2 init( )

Initializes the module - called at server startup.

=cut

sub init {
	$currentLang = getLanguage();
	loadStrings();
	setLocale();

	if ($::checkstrings) {
		checkChangedStrings();
	}
}

=head2 loadStrings( [ $argshash ] )

Load/Reload Strings files for server and plugins using cache if valid.
If stringcache file is valid this is loaded into memory and used as string hash, otherwise
string text files are parsed and new stringhash creted which stored as the stringcache file.

optional $argshash allows default behavious to be overridden, keys that can be set are:
'ignoreCache' - ignore cache file and reparse all files
'dontClear'   - don't clear current string hash before loading file
'dontSave'    - don't save new string hash to cache file [restart will use old cache file]
'storeString' - sub as alternative to storeString [e.g. for use by string editor]

=cut

sub loadStrings {
	my $args = shift;

	my ($newest, $sum, $files) = stringsFiles();

	my $stringCache = catdir( $prefs->get('cachedir'),
		Slim::Utils::OSDetect::OS() eq 'unix' ? 'stringcache' : 'strings.bin');

	my $stringCacheVersion = 2; # Version number for cache file
	# version 2 - include the sum of string file mtimes as an additional validation check

	# use stored stringCache if newer than all string files and correct version
	if (!$args->{'ignoreCache'} && -r $stringCache && ($newest < (stat($stringCache))[9])) {

		# check cache for consitency
		my $cacheOK = 1;

		$log->info("Retrieving string data from string cache: $stringCache");

		eval { $strings = retrieve($stringCache); };

		if ($@) {
			$log->warn("Tried loading string: $@");
		}

		if (!$@ && defined $strings &&
			defined $strings->{'version'} && $strings->{'version'} == $stringCacheVersion &&
			defined $strings->{'lang'} && $strings->{'lang'} eq $currentLang ) {

			$defaultStrings = $strings->{$currentLang};

		} else {
			$cacheOK = 0;
		}

		# check sum of mtimes matches that stored in stringcache
		if ($strings->{'mtimesum'} && $strings->{'mtimesum'} != $sum) {
			$cacheOK = 0;
		}

		# check for same list of strings files as that stored in stringcache
		if (scalar @{$strings->{'files'}} == scalar @$files) {
			for my $i (0 .. scalar @$files - 1) {
				if ($strings->{'files'}[$i] ne $files->[$i]) {
					$cacheOK = 0;
				}
			}
		} else {
			$cacheOK = 0;
		}

		return if $cacheOK;

		$log->info("String cache contains old data - reparsing string files");
	}

	# otherwise reparse all string files
	unless ($args->{'dontClear'}) {
		$strings = {
			'version' => $stringCacheVersion,
			'mtimesum'=> $sum,
			'lang'    => $currentLang,
			'files'   => $files,
		};
	}

	unless (defined $args->{'storeFailsafe'}) {
		$args->{'storeFailsafe'} = storeFailsafe();
	}

	for my $file (@$files) {

		$log->info("Loading string file: $file");

		loadFile($file, $args);

	}

	unless ($args->{'dontSave'}) {
		$log->info("Storing string cache: $stringCache");
		store($strings, $stringCache);
	}

	$defaultStrings = $strings->{$currentLang};

}

sub loadAdditional {
	my $lang = shift;
	
	if ( exists $strings->{$lang} ) {
		return $strings->{$lang};
	}
	
	for my $file ( @{ $strings->{files} } ) {
		$log->info("Loading string file for additional language $lang: $file");
		
		my $args = {
			storeString => sub {
				local $currentLang = $lang;
				storeString( @_ );
			},
		};

		loadFile( $file, $args );
		
		main::idleStreams();
	}
	
	return $strings->{$lang};
}

sub stringsFiles {
	my @files;
	my $newest = 0; # mtime of newest file
	my $sum = 0;    # sum of all mtimes

	# server string file
	my $serverPath = Slim::Utils::OSDetect::dirsFor('strings');
	push @files, catdir($serverPath, 'strings.txt');

	# plugin string files
	for my $path ( Slim::Utils::PluginManager->pluginRootDirs() ) {
		push @files, catdir($path, 'strings.txt');
	}

	# custom string file
	push @files, catdir($serverPath, 'custom-strings.txt');

	# plugin custom string files
	for my $path ( Slim::Utils::PluginManager->pluginRootDirs() ) {
		push @files, catdir($path, 'custom-strings.txt');
	}
	
	if ( main::SLIM_SERVICE ) {
		push @files, catdir($serverPath, 'slimservice-strings.txt');
	}

	# prune out files which don't exist and find newest
	my $i = 0;
	while (my $file = $files[$i]) {
		if (-r $file) {
			my $moddate = (stat($file))[9];
			$sum += $moddate;
			if ($moddate > $newest) {
				$newest = $moddate;
			}
			$i++;
		} else {
			splice @files, $i, 1;
		}
	}

	return $newest, $sum, \@files;
}

sub loadFile {
	my $file = shift;
	my $args = shift;

	# Force the UTF-8 layer opening of the strings file.
	open(my $fh, '<:utf8', $file) || do {
		logError("Couldn't open $file - FATAL!");
		die;
	};
	
	parseStrings($fh, $file, $args);
	
	close $fh;
}

sub parseStrings {
	my ( $fh, $file, $args ) = @_;

	my $string = '';
	my $language = '';
	my $stringname = '';
	my $stringData = {};
	my $ln = 0;

	my $store = $args->{'storeString'} || \&storeString;

	# split on both \r and \n
	# This caters for unix format (\n), DOS format (\r\n)
	# and mac format (\r) files
	# It also obviates the need to strip trailing \n or \r
	# from the end of lines
	LINE: for my $line ( <$fh> ) {

		$ln++;

		# skip lines starting with # (comments?)
		next if $line =~ /^#/;
		# skip lines containing nothing but whitespace
		# (this includes empty lines)
		next if $line !~ /\S/;

		if ($line =~ /^(\S+)$/) {

			&$store($stringname, $stringData, $file, $args);

			$stringname = $1;
			$stringData = {};
			$string = '';
			next LINE;

		} elsif ($line =~ /^\t(\S*)\t(.+)$/) {

			my $one = $1;
			$string = $2;

			if ($one =~ /./) {
				$language = uc($one);
			}

			if ($stringname eq 'LANGUAGE_CHOICES') {
				$strings->{'langchoices'}->{$language} = $string;
				next LINE;
			}

			if (defined $stringData->{$language}) {
				$stringData->{$language} .= "\n$string";
			} else {
				$stringData->{$language} = $string;
			}

		} else {

			logError("Parsing line $ln: $line");
		}
	}

	&$store($stringname, $stringData, $file, $args);
}

sub storeString {
	my $name = shift || return;
	my $curString = shift;
	my $file = shift;
	my $args = shift;

	return if ($name eq 'LANGUAGE_CHOICES');
	
	if ( main::SLIM_SERVICE ) {
		# Store all languages so we can have per-client language settings
		for my $lang ( keys %{ $strings->{langchoices} } ) {
			$strings->{$lang}->{$name} = $curString->{$lang} || $curString->{$failsafeLang};
		}
		return;
	}

	if ($log->is_info && defined $strings->{$currentLang}->{$name} && defined $curString->{$currentLang} && 
			$strings->{$currentLang}->{$name} ne $curString->{$currentLang}) {
		$log->info("redefined string: $name in $file");
	}

	if (defined $curString->{$currentLang}) {
		$strings->{$currentLang}->{$name} = $curString->{$currentLang};

	} elsif (defined $curString->{$failsafeLang}) {
		$strings->{$currentLang}->{$name} = $curString->{$failsafeLang};
		$log->debug("Language $currentLang using $failsafeLang for $name in $file");
	}

	if ($args->{'storeFailsafe'} && defined $curString->{$failsafeLang}) {

		$strings->{$failsafeLang}->{$name} = $curString->{$failsafeLang};
	}
}

# access strings

=head2 string ( $token )

Return localised string for token $token, or ''.

=cut

sub string {
	my $token = uc(shift);

	my $string = $defaultStrings->{$token};
	logBacktrace("missing string $token") if ($token && !defined $string);

	if ( @_ ) {
		return sprintf( $string, @_ );
	}
	
	return $string;
}

=head2 clientString( $client, $token )

Same as string but uses $client->string if client is available.
Also available as cstring().

=cut

sub clientString {
	my $client = shift;
	
	if ( blessed($client) ) {
		return $client->string(@_);
	}
	else {
		return string(@_);
	}
}

*cstring = \&clientString;

=head2 getString ( $token )

Return localised string for token $token, or token itself.

=cut

sub getString {
	my $token = shift;

	my $string = $defaultStrings->{uc($token)};
	$string = $token if ($token && !defined $string);

	if ( @_ ) {
		return sprintf( $string, @_ );
	}
	
	return $string;
}

=head2 stringExists ( $token )

Return boolean indicating whether $token exists.

=cut

sub stringExists {
	my $token = uc(shift);
	return (defined $defaultStrings->{$token}) ? 1 : 0;
}

=head2 setString ( $token, $string )

Set string for $token to $string.  Used to override string definitions parsed from string files.
The new definition is lost if the language is changed.

=cut

sub setString {
	my $token = uc(shift);
	my $string = shift;

	$log->debug("setString token: $token to $string");
	$defaultStrings->{$token} = $string;
}

=head2 defaultStrings ( )

Returns hash of tokens to localised strings for default language.

=cut

sub defaultStrings {
	return $defaultStrings;
}

# get & set languages

sub languageOptions {
	return $strings->{langchoices};
}

sub getLanguage {
	return $prefs->get('language') || $failsafeLang;
}

sub setLanguage {
	my $lang = shift;

	if ($strings->{'langchoices'}->{$lang}) {

		$prefs->set('language', $lang);
		$currentLang = $lang;

		loadStrings({'ignoreCache' => 1});
		setLocale();

		for my $client ( Slim::Player::Client::clients() ) {
			$client->display->displayStrings(clientStrings($client));
		}

	}
}

sub failsafeLanguage {
	return $failsafeLang;
}

sub clientStrings {
	my $client = shift;
	
	if ( main::SLIM_SERVICE ) {
		if ( my $override = $client->languageOverride ) {
			return $strings->{ $override } || $strings->{ $failsafeLang };
		}
		
		return $strings->{ $prefs->client($client)->get('language') } || $strings->{$failsafeLang};
	}
	
	my $display = $client->display;

	if (storeFailsafe() && ($display->isa('Slim::Display::Text') || $display->isa('Slim::Display::SqueezeboxG')) ) {

		unless ($strings->{$failsafeLang}) {
			$log->info("Reparsing strings as client requires failsafe language");
			loadStrings({'ignoreCache' => 1});
		}

		return $strings->{$failsafeLang};

	} else {
		return $defaultStrings;
	}
}

sub storeFailsafe {
	return ($currentLang ne $failsafeLang &&
			($prefs->get('loadFontsSqueezeboxG') || $prefs->get('loadFontsText') ) &&
			$currentLang !~ /CS|DE|DA|EN|ES|FI|FR|IT|NL|NO|PT|SV/ ) ? 1 : 0;
}


# Timer task to check mtime of string files and reload if they have changed.
# Started by init when --checkstrings is present on command line.
my $lastChange = time;

sub checkChangedStrings {

	my $reload;

	for my $file (@{$strings->{'files'}}) {
		if ((stat($file))[9] > $lastChange) {
			$log->info("$file updated - reparsing");
			loadFile($file);
			$reload ||= time;
		}
	}

	if ($reload) {
		$lastChange = $reload;
	}

	Slim::Utils::Timers::setTimer(undef, time + 1, \&checkChangedStrings);
}

sub setLocale {
	my $locale = string('LOCALE' . (Slim::Utils::OSDetect::isWindows() ? '_WIN' : '') );
	$locale .= Slim::Utils::Unicode::currentLocale() =~ /utf8/i ? '.UTF-8' : '';

	setlocale( LC_TIME, $locale );
}


1;
