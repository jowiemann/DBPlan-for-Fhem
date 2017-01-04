# $Id: 98_DBPlan.pm 37909 2016-10-29 13:58:00Z jowiemann $
##############################################################################
#
#     98_DBPlan.pm
#
#     Calls the URL: http://reiseauskunft.bahn.de/bin/query.exe/dox?S=departure&Z=destination&start=1&rt=1
#     with the given attributes. 
#     S=departure will be replace with "S=".AttrVal($name, "dbplan_departure", undef)
#     Z=destination will be replace with "S=".AttrVal($name, "dbplan_destination", undef)
#     See also the domumentation for external calls
#     Internet-Reiseauskunft der Deutschen Bahn AG
#     Externe Aufrufparameter und RÃ¼ckgabeparameter an externe Systeme
##############################################################################

use strict;                          
use warnings;                        
use Time::HiRes qw(gettimeofday);    
use HttpUtils;

use LWP;
use Digest::MD5 qw(md5_hex);

my $note_index;

sub DBPlan_Initialize($) {

    my ($hash) = @_;

    $hash->{DefFn}      = 'DBPlan_Define';
    $hash->{UndefFn}    = 'DBPlan_Undef';
    $hash->{SetFn}      = 'DBPlan_Set';
#    $hash->{GetFn}      = 'DBPlan_Get';
    $hash->{AttrFn}     = 'DBPlan_Attr';
    $hash->{ReadFn}     = 'DBPlan_Read';

    $hash->{AttrList} =
          "dbplan_base_url "
        . "dbplan_departure "
        . "dbplan_destination "
        . "dbplan_via_1 "
        . "dbplan_via_2 "
        . "dbplan_journey_prod:multiple-strict,Alle,ICE-Zuege,Intercity-Eurocityzuege,Interregio-Schnellzuege,Nahverkehr,"
        . "S-Bahnen,Busse,Schiffe,U-Bahnen,Strassenbahnen,Anruf-Sammeltaxi "
        . "dbplan_journey_opt:multiple-strict,Direktverbindung,Direktverbindung+Schlafwagen,Direktverbindung+Liegewagen,Fahrradmitnahme "
        . "dbplan_tariff_class:1,2 "
        . "dbplan_addon_options "
        . "dbplan_disable:0,1 "
        . "dbplan-remote-timeout "
        . "dbplan-remote-noshutdown:0,1 "
        . "dbplan-remote-loglevel:0,1,2,3,4,5 "
        . "dbplan-travel-date "
        . "dbplan-travel-time "
        . "dbplan-time-selection:arrive,depart "
        . "dbplan-default-char "
        . "dbplan-table-headers "
        . $readingFnAttributes;
}

sub DBPlan_Define($$) {

    my ( $hash, $def ) = @_;
    my @a = split( "[ \t][ \t]*", $def );
    
    return "DBPlan_Define - too few parameters: define <name> DBPlan <interval>" if ( @a < 3 );

    my $name 	= $a[0];
    my $inter	= 300;

    if(int(@a) == 3) { 
       $inter = int($a[2]); 
       if ($inter < 10 && $inter) {
          return "DBPlan_Define - interval too small, please use something > 10 (sec), default is 300 (sec)";
       }
    }

    $hash->{Interval} = $inter;

    Log3 $name, 3, "DBPlan_Define ($name) - defined with interval $hash->{Interval} (sec)";

    # initial request after 2 secs, there timer is set to interval for further update
    my $nt = gettimeofday()+$hash->{Interval};
    $hash->{TRIGGERTIME} = $nt;
    $hash->{TRIGGERTIME_FMT} = FmtDateTime($nt);
    RemoveInternalTimer($hash);
    InternalTimer($nt, "DBPlan_GetTimetable", $hash, 0);

    $hash->{BASE_URL} = AttrVal($name, "dbplan_base_url", 'http://reiseauskunft.bahn.de/bin/query.exe/dox?S=departure&Z=destination&start=1&rt=1');

    $hash->{STATE} = 'initialized';
    
    return undef;
}

sub DBPlan_Undef($$) {
    my ($hash, $arg) = @_; 
    my $name = $hash->{NAME};

    RemoveInternalTimer($hash);

    Log3 $name, 3, "DBPlan_Undef ($name) - removed";

    return undef;                  
}

#sub DBPlan_Get($@) {
#	my ($hash, @param) = @_;
#	
#	return '"get Hello" needs at least one argument' if (int(@param) < 2);
#	
#	my $name = shift @param;
#	my $opt = shift @param;
#	if(!$DBPlan_gets{$opt}) {
#		my @cList = keys %DBPlan_gets;
#		return "Unknown argument $opt, choose one of " . join(" ", @cList);
#	}
#	
#	if($attr{$name}{formal} eq 'yes') {
#	    return $DBPlan_gets{$opt}.', sir';
#    }
#	return $DBPlan_gets{$opt};
#}

sub DBPlan_Set($@) {

   my ($hash, $name, $cmd, @val) = @_;

   my $list = "interval";
   $list .= " reread:noArg" if($hash->{STATE} ne 'disabled');
   $list .= " stop:noArg" if($hash->{STATE} eq 'active' || $hash->{STATE} eq 'initialized');
   $list .= " start:noArg" if($hash->{STATE} eq 'stopped');

   if ($cmd eq 'interval')
   {
      if (int @val == 1 && $val[0] > 10) 
      {
         $hash->{Interval} = $val[0];

         # initial request after 2 secs, there timer is set to interval for further update
         my $nt	= gettimeofday()+$hash->{Interval};
         $hash->{TRIGGERTIME} = $nt;
         $hash->{TRIGGERTIME_FMT} = FmtDateTime($nt);
         if($hash->{STATE} eq 'active' || $hash->{STATE} eq 'initialized') {
            RemoveInternalTimer($hash);
            InternalTimer($nt, "DBPlan_GetTimetable", $hash, 0);
            Log3 $name, 3, "DBPlan_Set ($name) - restarted with new timer interval $hash->{Interval} (sec)";
         } else {
            Log3 $name, 3, "DBPlan_Set ($name) - new timer interval $hash->{Interval} (sec) will be active when starting/enabling";
         }
		 
         return undef;

      } elsif (int @val == 1 && $val[0] <= 10) {
          Log3 $name, 4, "DBPlan_Set ($name) - interval: $val[0] (sec) to small, continuing with $hash->{Interval} (sec)";
          return "DBPlan_Set - interval too small, please use something > 10, defined is $hash->{Interval} (sec)";
      } else {
          Log3 $name, 4, "DBPlan_Set ($name) - interval: no interval (sec) defined, continuing with $hash->{Interval} (sec)";
          return "DBPlan_Set - no interval (sec) defined, please use something > 10, defined is $hash->{Interval} (sec)";
      }
   } # if interval
   elsif ($cmd eq 'reread')
   {
      DBPlan_GetTimetable($hash);

      return undef;

   }
   elsif ($cmd eq 'stop')
   {
      $hash->{STATE} = 'stopped';
      RemoveInternalTimer($hash);    
      Log3 $name, 3, "DBPlan_Set ($name) - interval timeer stopped";

      return undef;

   } # if stop
   elsif ($cmd eq 'start')
   {
      RemoveInternalTimer($hash);
      InternalTimer(gettimeofday()+2, "DBPlan_GetTimetable", $hash, 0) if ($hash->{STATE} eq "stopped");
      $hash->{STATE}='initialized';
      Log3 $name, 3, "DBPlan_Set ($name) - interval timer started with interval $hash->{Interval} (sec)";

      return undef;
   } # if start

   return "DBPlan_Set ($name) - Unknown argument $cmd or wrong parameter(s), choose one of $list";

}

sub DBPlan_Attr(@) {
   my ($cmd,$name,$attrName,$attrVal) = @_;
   my $hash = $defs{$name};

   # $cmd can be "del" or "set"
   # $name is device name
   # attrName and attrVal are Attribute name and value

   if ($cmd eq "set") {
     if ($attrName eq "dbplan-travel-date") {
       if (!($attrVal =~ m/(0[1-9]|1[0-9]|2[0-9]|3[01]).(0[1-9]|1[012]).\d\d/s ) ) {
          Log3 $name, 4, "DBPlan_Attr ($name) - $attrVal is a wrong date";
          return ("DBPlan_Attr: $attrVal is a wrong date. Format is dd.mm.yy");
       }

     } elsif ($attrName eq "dbplan-travel-time") {
       if (!($attrVal =~ m/(?:0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]/s)) {
          Log3 $name, 4, "DBPlan_Attr ($name) - $attrVal is a wrong time";
          return ("DBPlan_Attr: $attrVal is a wrong time. Format is hh:mm");
       }
     }

   }
	
   if ($attrName eq "dbplan_disable") {
      if($cmd eq "set") {
         if($attrVal eq "0") {
            RemoveInternalTimer($hash);
            InternalTimer(gettimeofday()+2, "DBPlan_GetTimetable", $hash, 0) if ($hash->{STATE} eq "disabled");
            $hash->{STATE}='initialized';
            Log3 $name, 4, "DBPlan_Attr ($name) - interval timer enabled with interval $hash->{Interval} (sec)";
         } else {
            $hash->{STATE} = 'disabled';
            RemoveInternalTimer($hash);    
            Log3 $name, 4, "DBPlan_Attr ($name) - interval timer disabled";
         }
         $attr{$name}{$attrName} = $attrVal;   

      } elsif ($cmd eq "del") {
         RemoveInternalTimer($hash);
         InternalTimer(gettimeofday()+2, "DBPlan_GetTimetable", $hash, 0) if ($hash->{STATE} eq "disabled");
         $hash->{STATE}='initialized';
         Log3 $name, 4, "DBPlan_Attr ($name) - interval timer enabled with interval $hash->{Interval} (sec)";
      }

   } elsif ($attrName eq "dbplan_base_url") {
      if($cmd eq "set") {
        $hash->{BASE_URL} = $attrVal;
        $attr{$name}{$attrName} = $attrVal;   
        Log3 $name, 4, "DBPlan_Attr ($name) - url set to " . $hash->{BASE_URL};
      } elsif ($cmd eq "del") {
        $hash->{BASE_URL} = 'http://reiseauskunft.bahn.de/bin/query.exe/dox?S=departure&Z=destination&start=1&rt=1';
        Log3 $name, 4, "DBPlan_Attr ($name) - url set to " . $hash->{BASE_URL};
      }

   } else {
      if($cmd eq "set") {
          $attr{$name}{$attrName} = $attrVal;   
          Log3 $name, 4, "DBPlan_Attr ($name) - set $attrName : $attrVal";
      } elsif ($cmd eq "del") {
          Log3 $name, 4, "DBPlan_Attr ($name) - deleted $attrName : $attrVal";
      }
   }

   return undef;
}

#####################################
# generating bit pattern for DB products
#
# Bit Nummer Produktklasse
#         0  ICE-ZÃ¼ge
#         1  Intercity- und EurocityzÃ¼ge
#         2  Interregio- und SchnellzÃ¼ge
#         3  Nahverkehr, sonstige ZÃ¼ge
#         4  S-Bahnen
#         5  Busse
#         6  Schiffe
#         7  U-Bahnen
#         8  StraÃŸenbahnen
#         9  Anruf Sammeltaxi
#
sub DBPlan_products($)
{
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my @prod_list = split("(,|\\|)", AttrVal($name, "dbplan_journey_prod", "none"));

    my $products = 0;

    return $products if((grep { /^(Alle)$/ } @prod_list));

    $products += 1 if((grep { /^(ICE-Zuege)$/ } @prod_list));
    $products += 2 if((grep { /^(Intercity-Eurocityzuege)$/ } @prod_list));
    $products += 4 if((grep { /^(Interregio-Schnellzuege)$/ } @prod_list));
    $products += 8 if((grep { /^(Nahverkehr)$/ } @prod_list));
    $products += 16 if((grep { /^(S-Bahnen)$/ } @prod_list));
    $products += 32 if((grep { /^(Busse)$/ } @prod_list));
    $products += 64 if((grep { /^(Schiffe)$/ } @prod_list));
    $products += 128 if((grep { /^(U-Bahnen)$/ } @prod_list));
    $products += 256 if((grep { /^(Strassenbahnen)$/ } @prod_list));
    $products += 512 if((grep { /^(Anruf-Sammeltaxi)$/ } @prod_list));

    return $products;
}

#####################################
# generating bit pattern DB options
sub DBPlan_options($)
{
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my @opt_list = split("(,|\\|)", AttrVal($name, "dbplan_journey_opt", "none"));

    my $options = 0;

    $options += 1 if((grep { /^(Direktverbindung)$/ } @opt_list));
    $options += 2 if((grep { /^(Direktverbindung+Schlafwagen)$/ } @opt_list));
    $options += 4 if((grep { /^(Direktverbindung+Liegewagen)$/ } @opt_list));
    $options += 8 if((grep { /^(Fahrradmitnahme)$/ } @opt_list));

    return $options;
}

#####################################
# Parsing the DB travel notes
sub DBPlan_Parse_Travel_Notes($)
{
    my ($hash, $err, $data) = @_;
    my $name = $hash->{NAME};
    my $index = $hash->{note_index};
	
    if ($err) {
        Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: got error in callback: $err";
        return;
    }

    if($data eq "")
    {
        Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: received http without any data after requesting DB travel notes";
        return;
    }

    my $pattern;

    readingsBeginUpdate($hash);

    Log3 $name, 5, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: Callback called: Hash: $hash, data: $data\r\n";

    ##################################################################################
    # only for debugging
    if(AttrVal($name, "verbose", 3) >= 5) {
       readingsBulkUpdate( $hash, "dbg_travel_notes_HTML_1", $data );
    }

    ##################################################################################
    # Parsing notification
    $pattern = '(Fahrt f&#228;llt aus)';

    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel notification for plan $index read successfully";
       readingsBulkUpdate( $hash, "travel_note_text_$index", "Fahrt faellt aus");
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no canceling for plan $index found";
    }

    ##################################################################################
    # Parsing notification
    $pattern = '(Aktuelle Informationen zu der Verbindung)';

    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel notification for plan $index read successfully";
       readingsBulkUpdate( $hash, "travel_note_text_$index", "Aktuelle Informationen liegen vor");
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no actual informations for plan $index found";
    }

    ##################################################################################
    # Parsing notification
    $pattern = 'alt="".\/\>Angebot.w\&\#228\;hlen.*?\>(.*?)\<\/div\>.\<div.class="querysummary1.clickarea"';

    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel notification for plan $index read successfully";
       readingsBulkUpdate( $hash, "travel_note_text_$index", DBPlan_html2txt($1));
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no travel notes for plan $index found";
    }

    ##################################################################################
    # Parsing notification
    $pattern = 'alt="".\/\>Angebot.w\&\#228\;hlen(.*?)\<\/div\>.\<div class="clickarea';

    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel notification for plan $index read successfully";
       readingsBulkUpdate( $hash, "travel_note_text_$index", DBPlan_html2txt($1));
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no travel notes for plan $index found";
    }

    my $plattform = "";

    ##################################################################################
    # Parsing deaparture plattform
    $pattern = '\<\/span\>.*?(Gl.*?)\<br.\/\>.\<\/div\>.\<div.class="rline.haupt.mot"\>';

    $plattform = AttrVal($name, "dbplan-default-char", "none");
    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel departure plattform for plan $index read successfully";
       $plattform = $1;
       $plattform =~ s/\n//g;
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no travel departure plattform for plan $index found";
    }

    ##################################################################################
    # Parsing departure place
    $pattern = '"rline.haupt.stationDark.routeStart".style="."\>.\<span.class="bold"\>(.*?)\<\/span\>';

    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel departure for plan $index read successfully";
       readingsBulkUpdate( $hash, "travel_departure_$index", $1.' - '.$plattform);
    } else {
       readingsBulkUpdate( $hash, "travel_departure_$index", $plattform) if(AttrVal($name, "dbplan-default-char", "none") ne "delete");
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no travel departure for plan $index found";
    }

    ##################################################################################
    # Parsing destination plattform
    $pattern = '\<div.class="rline.haupt.routeEnd.*?"\>.*?(Gl.*?)\<br.\/\>.\<span.class="bold"\>.*?\<\/span\>';

    $plattform = "none";
    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel destination plattform for plan $index read successfully";
       $plattform = $1;
       $plattform =~ s/\n//g;
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no travel destination plattform for plan $index found";
    }

    ##################################################################################
    # Parsing destination place
    $pattern = '\<div.class="rline.haupt.stationDark.routeEnd"\>.*?\<br.\/\>.\<span.class="bold"\>(.*?)\<\/span\>';

    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel destination for plan $index read successfully";
       readingsBulkUpdate( $hash, "travel_destination_$index", $1.' - '.$plattform);
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no travel destination for plan $index found";
       readingsBulkUpdate( $hash, "travel_destination_$index", $plattform) if(AttrVal($name, "dbplan-default-char", "none") ne "delete");
    }

    readingsEndUpdate($hash, 1);

    ##################################################################################
    # Recursiv call until index = 0
    $index -= 1;
	
    if($index <= 0) {
       Log3 $name, 4, "DBPlan ($name) - DB notes: parsed all notes";
       return;
    }

    $hash->{note_index} = $index;
    $hash->{url}        = ReadingsVal($name, "travel_note_link_$index", "");
    $hash->{callback}   = \&DBPlan_Parse_Travel_Notes;
    $hash->{noshutdown} = AttrVal($name, "dbplan-remote-noshutdown", 0);
    $hash->{timeout}    = AttrVal($name, "dbplan-remote-timeout", 5);
    $hash->{loglevel}   = AttrVal($name, "dbplan-remote-loglevel", 4);

    Log3 $name, 4, "DBPlan ($name) - DB notes ($index): next getting $hash->{url}";

    HttpUtils_NonblockingGet($hash);

    return;
}

#####################################
# Getting the DB main timetable
sub DBPlan_GetTimetable($)
{
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $base_url = $hash->{BASE_URL};
    my $departure = AttrVal($name, "dbplan_departure", undef);
    my $destination = AttrVal($name, "dbplan_destination", undef);

    my @prod_list = split("(,|\\|)", AttrVal($name, "dbplan_journey_prod", "none"));
    my @opt_list = split("(,|\\|)", AttrVal($name, "dbplan_journey_opt", "none"));

    my $products = DBPlan_products($hash);
    my $options = DBPlan_options($hash);
	
    if($hash->{STATE} eq 'active' || $hash->{STATE} eq 'initialized') {
       my $nt = gettimeofday()+$hash->{Interval};
       $hash->{TRIGGERTIME} = $nt;
       $hash->{TRIGGERTIME_FMT} = FmtDateTime($nt);
       RemoveInternalTimer($hash);
       InternalTimer($nt, "DBPlan_GetTimetable", $hash, 1) if (int($hash->{Interval}) > 0);
       Log3 $name, 5, "DBPlan ($name) - DB timetable: restartet InternalTimer with $hash->{Interval}";
    }

    unless(defined($departure))
    {
        Log3 $name, 3, "DBPlan ($name) - DB timetable: no valid departure defined";
        return;
    }

    unless(defined($destination))
    {
        Log3 $name, 3, "DBPlan ($name) - DB timetable: no valid destination defined";
        return; 
    }

    $departure =~ s/ /+/g;
    $base_url =~ s/departure/$departure/;

    $destination =~ s/ /+/g;
    $base_url =~ s/destination/$destination/;

    $base_url .= '&journeyProducts='.$products if($products > 0);
    $base_url .= '&journeyOptions='.$options if($options > 0);

    my $oTmp = AttrVal($name, "dbplan_via_1", "");
    $base_url .= '&V1='.$oTmp if($oTmp ne "");

    $oTmp = AttrVal($name, "dbplan_via_2", "");
    $base_url .= '&V2='.$oTmp if($oTmp ne "");

    $oTmp = AttrVal($name, "dbplan_tariff_class", "");
    $base_url .= '&tariffClass='.$oTmp if($oTmp ne "");

    $oTmp = AttrVal($name, "dbplan_addon_options", "");
    $base_url .= $oTmp if($oTmp ne "");

    my $travel_date = AttrVal($name, "dbplan-travel-date", "");
    my $travel_time = AttrVal($name, "dbplan-travel-time", "");
    my $time_sel = AttrVal($name, "dbplan-time-selection", "depart");

    $base_url .= '&date='.$travel_date if($travel_date ne "");

    $base_url .= '&time='.$travel_time if($travel_time ne "");

    if($travel_date ne "" || $travel_time ne "") {
      $base_url .= '&timesel='.$time_sel;
    }

    $base_url .= '&'; # see parameter description

    Log3 $name, 3, "DBPlan ($name) - DB timetable: calling url: $base_url";

    $hash->{url}        = $base_url;
    $hash->{callback}   = \&DBPlan_Parse_Timetable;
    $hash->{noshutdown} = AttrVal($name, "dbplan-remote-noshutdown", 0);
    $hash->{timeout}    = AttrVal($name, "dbplan-remote-timeout", 5);
    $hash->{loglevel}   = 4;

    Log3 $name, 4, "DBPlan ($name) - DB timetable: next getting $hash->{url}";

    HttpUtils_NonblockingGet($hash);

}

#####################################
# Parsing the DB main timetable
#      delete($hash->{READINGS})
sub DBPlan_Parse_Timetable($)
{
    my ($hash, $err, $data) = @_;
    my $name = $hash->{NAME};

    delete($hash->{error}) if(exists($hash->{error}));
    
    if ($err) {
       Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Timetable: got error in callback: $err";
       return;
    }

    if($data eq "")
    {
       Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Timetable: received http without any data after requesting DB timetable";
       return;
    }

    Log3 $name, 5, "DBPlan ($name) - DBPlan_Parse_Timetable: Callback called with Hash: $hash, data: $data\r\n";

    if(AttrVal($name, "verbose", 3) >= 5) {
       $hash->{Timetable} = $data;
    }

    ##################################################################################
    # only for debugging
    if(AttrVal($name, "verbose", 3) >= 5) {
       readingsBeginUpdate($hash);
       readingsBulkUpdate( $hash, "dbg_db_plan", $data );
       readingsEndUpdate( $hash, 1 );
    }

    my $i;
    my $ret;
    my $defChar = AttrVal($name, "dbplan-default-char", "none");

    $ret = fhem("deletereading $name dbg.*", 1);

    if($defChar eq "delete") {

      $ret = fhem("deletereading $name plan.*", 1);
      $ret = fhem("deletereading $name travel.*", 1);
      Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Timetable: readings deleted";

    } else {

      $defChar =" " if($defChar eq "nochar");
	
      readingsBeginUpdate($hash);

      for($i=1; $i<=3; $i++) {

         readingsBulkUpdate( $hash, "plan_error", $defChar);
         readingsBulkUpdate( $hash, "plan_departure_$i", $defChar);
         readingsBulkUpdate( $hash, "plan_arrival_$i", $defChar);
         readingsBulkUpdate( $hash, "plan_connection_$i", $defChar);
         readingsBulkUpdate( $hash, "plan_departure_delay_$i", $defChar );
         readingsBulkUpdate( $hash, "plan_arrival_delay_$i", $defChar );
         readingsBulkUpdate( $hash, "travel_duration_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_change_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_price_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_note_link_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_note_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_note_text_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_departure_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_destination_$i", $defChar);
      }

      Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Timetable: readings filled with: $defChar";
    }

    readingsEndUpdate( $hash, 1 );

    my $pattern = '\<div class="haupt bline leftnarrow"\>(.*?)\<div class="bline bggrey stdpadding"\>';

    if ($data =~ m/MOBI_ASK_DEU_de_error/s) {
        Log3 $name, 3, "DBPlan ($name) - error in DB request. Bitte Log prÃ¼fen.";
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "plan_error", "error in DB request" );
        readingsEndUpdate( $hash, 1 );
        if ($data =~ m/$pattern/s) {
           my $error_text = DBPlan_html2txt($1);
           Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Timetable: error description of DB timetable request: $error_text";
        }
        return;
    }


    Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Timetable: successfully identified";

    ##################################################################################
    # Parsing connection plans. DB timetable will show three connection plans
    $pattern = '\<td.class="overview.timelink"\>(.*?)\/td\>\<\/tr\>\<tr'
              .'.*?'
              .'\<td.class="overview.timelink"\>(.*?)\/td\>\<\/tr\>\<tr'
              .'.*?'
              .'\<td class="overview timelink"\>(.*?)\/td\>\<\/tr\>\<tr';

    if ($data =~ m/$pattern/s) {
      ##################################################################################
      # only for debugging
      if(AttrVal($name, "verbose", 3) >= 5) {
         readingsBeginUpdate($hash);
         readingsBulkUpdate( $hash, "dbg_connect_plan_1", $1 ) if(defined($1));
         readingsBulkUpdate( $hash, "dbg_connect_plan_2", $2 ) if(defined($2));
         readingsBulkUpdate( $hash, "dbg_connect_plan_3", $3 ) if(defined($3));
         readingsEndUpdate( $hash, 1 );
      }
      Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Timetable: connection plans read successfully";

      $hash->{STATE}='active' if($hash->{STATE} eq 'initialized' || $hash->{STATE} eq 'stopped');

    } else {
      Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Timetable: no connection plans found";
      return;
    }

    ##################################################################################
    # Parsing each connection plan (Three is default)

    my @plan;
    my @planrow;

    my $notelink = '';

    $plan[1] = $1;
    $plan[2] = $2;
    $plan[3] = $3;

    my $rc = eval {
        require HTML::TableExtract;
        HTML::TableExtract->import();
        1;
    };

    unless($rc)
    {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "plan_error", "Error loading HTML::TableExtract" );
        readingsEndUpdate( $hash, 1 );
        Log3 $name, 2, "DBPlan ($name) - Timetable: Error loading HTML::TableExtract. May be this module is not installed.";
        return;
    }

    $data =~ s/\<td.class="ovHeadNoPad"\>&nbsp;\<\/td\>/\<td class="ovHead"\>\nLeer\<br \/\>\nLeer\n\<\/td\>/g;
    $data =~ s/&nbsp;/ /g;

    # Log3 $name, 2, $data;
    
    my @headers = split(/ /, AttrVal($name, "dbplan-table-headers", "An Leer Dauer Preis"));
    Log3 $name, 3, "DBPlan ($name) - Timetable-Headers: @headers";
    my $timetable = HTML::TableExtract->new( headers => \@headers );
    my $retRow = "";

    Log3 $name, 4, "DBPlan ($name) - Timetable: data for HTML::TableExtract: \n $data";

    $ret = $timetable->parse($data);

    $i = 0;
    my $filler = "";

    foreach my $ts ($timetable->tables) {
      foreach my $row ($timetable->rows) {

        Log3 $name, 4, "DBPlan ($name) - Timetable-Org1: $retRow";

        if(@$row) {
          my @myValues = map defined($_) ? $_ : '', @$row;
          $retRow = join(';', @myValues);
          $retRow =~ s/\n|\r/;/g; #s,[\r\n]*,,g;
          if($defChar ne "delete") {
            $retRow =~ s/Â /$defChar/g;
          } else {
            $retRow =~ s/Â /$filler/g;
          }
        }

        Log3 $name, 4, "DBPlan ($name) - Timetable-Org2: $retRow";

        $planrow[$i++] = $retRow;
      }
    }

    unless(@planrow) {
      Log3 $name, 2, "DBPlan ($name) - Timetable: HTML::TableExtract failed.";
      readingsBeginUpdate($hash);
      readingsBulkUpdate( $hash, "plan_error", "Error HTML::TableExtract failed" );
      readingsEndUpdate( $hash, 1 );

      return;
    }

    readingsBeginUpdate($hash);

    for($i=1; $i<=3; $i++) {

       my ($d_time, $a_time, $d_delay, $a_delay, $change, $duration, $prod, $price) = split(";", $planrow[$i]);

       $prod = "" unless(defined($prod));
       $price = "" unless(defined($price));

       Log3 $name, 4, "DBPlan ($name) - Timetable: $d_time - $a_time - $d_delay - $a_delay - $change - $duration - $prod - $price";

       readingsBulkUpdate( $hash, "plan_departure_$i", $d_time ) if(trim($d_time) ne "");
       readingsBulkUpdate( $hash, "plan_arrival_$i", $a_time ) if(trim($a_time) ne "");

       readingsBulkUpdate( $hash, "plan_connection_$i", $prod ) if(trim($prod) ne "");

       readingsBulkUpdate( $hash, "plan_departure_delay_$i", $d_delay ) if(trim($d_delay) ne "");
       readingsBulkUpdate( $hash, "plan_arrival_delay_$i", $a_delay ) if(trim($a_delay) ne "");

       readingsBulkUpdate( $hash, "plan_travel_duration_$i", $duration ) if(trim($duration) ne "");
       readingsBulkUpdate( $hash, "plan_travel_change_$i", $change ) if(trim($change) ne "");

       readingsBulkUpdate( $hash, "travel_price_$i", $price) if(trim($price) ne "");

  	##################################################################################
	# Parsing travel notes (notifications)
       # http://www.img-bahn.de/v/1504/img/achtung_17x19_mitschatten.png
       $pattern = '\<img src=".*?img\/(.*?)_.*?"\ \/\>\<\/a\>';
       if ($plan[$i] =~ m/$pattern/s) {
         readingsBulkUpdate( $hash, "travel_note_$i", $1) if(trim($1) ne "");
         readingsBulkUpdate( $hash, "plan_departure_delay_$i", "Hinweise" )  if(trim($1) ne "");
         readingsBulkUpdate( $hash, "plan_arrival_delay_$i", "Hinweise" )  if(trim($1) ne "");
         Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Timetable: travel note for plan $i read successfully";
       } else {
         Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Timetable: no travel note for plan $i found";
       }

  	##################################################################################
	# Parsing URL for further informations about travel notes (notifications)
       $pattern = '\<a href="(.*?)amp\;"\>';
       if ($plan[$i] =~ m/$pattern/s) {
          $notelink = $1;
          $notelink =~ s/amp\;//g;
          Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Timetable: travel note URL for plan $i: $notelink";
          readingsBulkUpdate( $hash, "travel_note_link_$i", $notelink)  if(trim($notelink) ne "");
       } else {
          Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Timetable: no travel note URL for plan $i found";
       }

    } #end for
    readingsEndUpdate( $hash, 1 );

    ##################################################################################
    # First call of recursiv call of URL for further informations about travel notes (notifications)
    $hash->{note_index} = $i-1;
    $hash->{url}        = ReadingsVal($name, "travel_note_link_$hash->{note_index}", "");
    $hash->{callback}   = \&DBPlan_Parse_Travel_Notes;
    $hash->{noshutdown} = AttrVal($name, "dbplan-remote-noshutdown", 0);
    $hash->{timeout}    = AttrVal($name, "dbplan-remote-timeout", 5);
    $hash->{loglevel}   = AttrVal($name, "dbplan-remote-loglevel", 4);

    Log3 $name, 4, "DBPlan ($name) - DB notes ($hash->{note_index}): next getting $hash->{url}";

    HttpUtils_NonblockingGet($hash);

    return undef;
}

#####################################
# replaces all HTML entities to their utf-8 counter parts.
sub DBPlan_html2txt($)
{

    my ($string) = @_;

    $string =~ s/&nbsp;/ /g;
    $string =~ s/&amp;/&/g;
    $string =~ s/(\xe4|&auml;|\\u00e4|\\u00E4)/Ã¤/g;
    $string =~ s/(\xc4|&Auml;|\\u00c4|\\u00C4)/Ã„/g;
    $string =~ s/(\xf6|&ouml;|\\u00f6|\\u00F6)/Ã¶/g;
    $string =~ s/(\xd6|&Ouml;|\\u00d6|\\u00D6)/Ã–/g;
    $string =~ s/(\xfc|&uuml;|\\u00fc|\\u00FC)/Ã¼/g;
    $string =~ s/(\xdc|&Uuml;|\\u00dc|\\u00DC)/Ãœ/g;
    $string =~ s/(\xdf|&szlig;)/ÃŸ/g;
    $string =~ s/<.+?>//g;
    $string =~ s/(^\s+|\s+$)//g;

    return trim($string);

}

#####################################
# only for testing regular expressions
sub RegExTest()
{
#   my $test = '<h1>Fehler</h1> <div class="haupt bline"> Sehr geehrte Kundin, sehr geehrter Kunde,<br /><br /> Start/Ziel/Via oder &#228;quivalente Bahnh&#246;fe sind mehrfach vorhanden oder identisch. <br />Wir bitten Sie, Ihre Anfrage mit ge&#228;nderten Eingaben zu wiederholen. <br /><span class="bold"><br />Vielen Dank! <br />Ihr Team von www.bahn.de</span><br /> <br />Code: H9380<br /> </div> <div class="bline"> <a href="http://reiseauskunft.bahn.de/bin/detect.exe/dox?" ';

   my $test = ReadingsVal("DB_Test", "Notes_HTML_1", "none");

   my $pattern = '';

   $pattern = '"rline.haupt.stationDark.routeStart".style="."\>.\<span.class="bold"\>(.*?)\<\/span\>';

   if ($test =~ m/$pattern/s) {
      my $error_text = DBPlan_html2txt($1);
      return ("$1 \n\n$2 \n\n$3");
   }

   return ("Kein Ergebnis: $test");
}

1;

=pod
=begin html

<a name="DBPlan"></a>
<h3>DBPlan</h3>

<ul>
	This module provides a generic way to retrieve information remote from a Fritz!Box and store them in Readings. 
	It queries a given URL with Headers and data defined by attributes. 
	From the HTTP Response it extracts Readings named in attributes using Regexes also defined by attributes.
	<br><br>
	<b>Prerequisites</b>
	<ul>
		<br>
		<li>
			This Module uses the non blocking HTTP function HttpUtils_NonblockingGet provided by FHEM's HttpUtils in a new Version published in December 2013.<br>
			If not already installed in your environment, please update FHEM or install it manually using appropriate commands from your environment.<br>
		</li>
		
	</ul>
	<br>
       STATE will show the device status: 
	<ul>
		<li><b>initialized</b></li>
			the device is definied, but no successfully request and parsing has been done<br>
                     this stae will also be set when changing from stopped to start and disabled to enabled<br>
		<li><b>active</b></li>
			the device is working<br>
		<li><b>stopped</b></li>
			the device timer has been stopped. A reread is possibel<br>
		<li><b>disabled</b></li>
			the device is disabled.<br>

	</ul>

	<a name="DBPlandefine"></a>
	<b>Define</b>
	<ul>
		<br>
		<code>define &lt;name&gt; DBPlan &lt;Refrsh interval in seconds&gt;</code>
		<br><br>
		The module connects to the given URL every Interval seconds and then parses the response<br>
		<br>
		Example:<br>
		<br>
		<ul><code>define DBPlan_Test DBPlan 60</code></ul>
	</ul>
	<br>

	<a name="DBPlanconfiguration"></a>
	<b>Configuration of DBPlan</b><br><br>
	<ul>
		Example for a timetable query:<br><br>
		<ul><code>
                   attr DB_Test dbplan_departure KÃƒÂ¶ln-Weiden West
                   attr DB_Test dbplan_destination KÃƒÂ¶ln HBF
                   attr DB_Test room OPNV
		</code></ul>
	</ul>
	<br>

	<a name="DBPlanset"></a>
	<b>Set-Commands</b><br>
	<ul>
		<li><b>interval</b></li>
			set new interval time in seconds for parsing the DB time table<br>
		<li><b>reread</b></li>
			reread and parse the DB time table. Only active, if not state: disabled<br>
		<li><b>stop</b></li>
			stop interval timer, only active if state: active<br>
		<li><b>start</b></li>
			restart interval timer, only active if state: stopped<br>
	</ul>
	<br>
	<a name="DBPlanget"></a>
	<b>Get-Commands</b><br>
	<ul>
		none
	</ul>
	<br>

	<a name="DBPlanattr"></a>
	<b>Attributes</b><br><br>
	<ul>
		<li><a href="#readingFnAttributes">readingFnAttributes</a></li>
		<br>
		<li><b>dbplan_departure</b></li>
			place of departure<br>
		<li><b>dbplan_destination</b></li>
			place of destination<br>
		<li><b>dbplan_journey_prod</b></li>
			DB travel products like: ICE<br>
		<li><b>dbplan_journey_opt</b></li>
			DB journey options like: direct connection<br>
		<li><b>dbplan_via_1</b></li>
			DB first via station<br>
		<li><b>dbplan_via_2</b></li>
			DB second via station<br>
		<li><b>dbplan_tariff_class</b></li>
			DB tariff class: 1 or 2 class<br>
		<li><b>dbplan_addon_options</b></li>
			extended options like discribed in the api document: <li><a http://webcache.googleusercontent.com/search?q=cache:wzb_OlIUCBQJ:www.geiervally.lechtal.at/sixcms/media.php/1405/Parametrisierte%2520%25DCbergabe%2520Bahnauskunft(V%25205.12-R4.30c,%2520f%25FCr.pdf+&cd=3&hl=de&ct=clnk&gl=de
">Parametrisierte Ãœbergabe Bahnauskunft</a></li><br>
		<li><b>dbplan_disable</b></li>
			If set to 1 polling of DB Url will be stopped, setting to 0 or deleting will activate polling<br>
		<li><b>dbplan-default-char</b></li>
			Define a string which will be displayed if no information is available. Defaultstring: "none"<br>
			When defined "delete" the raeding will not be filled and is not available since an information excists<br>
			When defined "nochar" the raeding will not be filled with " "<br>
		<li><b>dbplan-remote-timeout</b></li>
			Define the timeout for all http get. Default is 5 seconds.<br>
		<li><b>dbplan-remote-noshutdown</b></li>
			Define the noshutdown for all http get. Default is 0=noshutdown connection.<br>
		<li><b>dbplan-remote-loglevel</b></li>
			Define the loglevel for all http get. Default is loglevel 4.<br>
		<li><b>dbplan-travel-date</b></li>
			Define the date of travel in dd.mm.yy. Default: actual date.<br>
		<li><b>dbplan-travel-time</b></li>
			Define the time of travel in hh:mm. Default: actual time.<br>
		<li><b>dbplan-travel-selection</b></li>
			Define if date / time is departure or arrival. Default: departure<br>
	</ul>
       <br>
	<a name="DBPlanReadings"></a>
	<b>Readings</b><br><br>
	<ul>
		<li><a href="#internalReadings">internalReadings</a></li>
		<br>
		<li><b>departure_(1..3)</b></li>
			time of departure<br>
		<li><b>arrival_(1..3)</b></li>
			time of arrival<br>
		<li><b>connection_(1..3)</b></li>
			type of connection<br>
		<li><b>departure_delay_(1..3)</b></li>
			delay time for departure<br>
		<li><b>arrival_delay_(1..3)</b></li>
			delay time for arrival<br>
		<li><b>travel_duration_(1..3)</b></li>
			travel duration time<br>
		<li><b>travel_change_(1..3)</b></li>
			travel plattform changings<br>
		<li><b>travel_price_(1..3)</b></li>
			travel price in EUR<br>
		<li><b>travel_note_(1..3)</b></li>
			travel note for travel plan<br>
		<li><b>travel_note_link_(1..3)</b></li>
			travel note link for further informations<br>
		<li><b>travel_note_text_(1..3)</b></li>
			travel note text<br>
		<li><b>travel_departure_(1..3)</b></li>
			informations about the departure and the plattform, if available<br>
		<li><b>travel_destination_(1..3)</b></li>
			informations about the destination and the plattform, if available<br>
	</ul>
</ul>

=end html
=cut
