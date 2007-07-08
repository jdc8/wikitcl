package require Mk4tcl
package require Wikit::Db
package require Wikit::Search
package require File
package require Convert
package require Direct
package require Html
package require fileutil

package require Debug
package require Url
package require Query
package require struct::queue
package require Http
package require Cookies
package require WikitRss

package require Honeypot
Honeypot init dir [file join $::config(docroot) captcha]

proc pest {req} {return 0}
catch {source [file join [file dirname [info script]] pest.tcl]}

package provide WikitWub 1.0

# create a queue of pending work
::struct::queue inQ
variable request ""

# ::Wikit::GetPage {id} -
# ::Wikit::Expand_HTML {text}
# ::Wikit::pagevars {id args} - assign values to named vars

# ::Wikit::SavePage $id $C $host $name

# LookupPage {name} - find/create a page named $name in db, return its id
# InfoProc {db name} - lookup $name in db,
# returns a list: /$id (with suffix of @ if the page is new), $name, modification $date

namespace eval WikitWub {
    variable readonly ""
    variable roT {title: Wiki is currently Read-Only

	<h1>The Wiki is currently in Maintenance Mode</h1>
	<p>No new edits can be accepted for the moment.</p>
	<p>Reason: $readonly</p>
	<p><a href='/$N'>Return to the page you were reading</a>.</p>
    }

    variable motd ""

    # page sent in response to a search
    variable searchT {
	<form action='/_search' method='get'>
	<p>Enter the search phrase:<input name='S' type='text' $search> Append an asterisk (*) to search page contents as well</p>
	<input type='hidden' name='_charset_'>
	</form>
	$C
    }

    proc div {ids content} {
	set divs ""
	foreach id $ids {
	    append divs "<div class='$id'>\n"
	}
	append divs [uplevel 1 subst [list $content]]
	append divs "\n"
	append divs [string repeat "\n</div>" [llength $ids]]
	return $divs
    }

    proc divID {ids content} {
	set divs ""
	foreach id $ids {
	    append divs "<div id='$id'>\n"
	}
	append divs [uplevel 1 subst [list $content]]
	append divs "\n"
	append divs [string repeat "\n</div>" [llength $ids]]
	return $divs
    }

    proc script { script } { 
	return "<script type='text/javascript'>$script</script>"
    }

    # return a search form
    proc searchF {} {
	return {<form action='/_search' method='get'>
	    <input type='hidden' name='_charset_'>
	    <input name='S' type='text' value='Search'>
	    </form>}
    }

    # page template for standard page decoration
    variable pageT {title: $name

	[div container {
	    [div header {<h1 class='title'>$Title</h1>}]
	    [expr {[info exists ro]?$ro:""}]
	    [div {wrapper content} {<p>$C</p>}]
	    <hr noshade />
	    [div footer {
		<p>[join $menu { - }]</p>
		<p>[searchF]</p>
	    }]
        }]
    }

    # page sent when constructing a reference page
    variable refs {title: References to $N

	[div container {
	    [div header [<h1> "References to [Ref $N]"]]
	    [div {wrapper content} {$C}]
	    <hr noshade />
	    [div footer {
		<p>[join $menu { - }]</p>
		<p>[searchF]</p>
	    }]
	}]
     }

    # page sent when editing a page
    variable edit {title: Editing $N

	[<form> method post action /_save/$N [subst {
	    [div header [<h1> "[Ref $N] [<input> type submit name save value Save {*}[expr {$nick eq {} ? {disabled 1} : {}}] {}]"]]
	    [<textarea> rows 30 cols 72 name C style width:100% $C]
	    <p />
	    [<input> type hidden name O value [list $date $who] {}]
	    [<input> type hidden name _charset_ {}]
	    [<input> type submit name save value Save {*}[expr {$nick eq "" ? {disabled 1} : {}}] {}]
	}]]
	<hr size=1>
	Editing quick-reference:
	<blockquote><font size=-1>
	<b>LINK</b> to <b>\[<a href='../6' target='_newWindow'>Wiki formatting rules</a>\]</b> - or to
	<b><a href='http://here.com/' target='_newWindow'>http://here.com/</a></b>
	- use <b>\[http://here.com/\]</b> to show as
	<b>\[<a href='http://here.com/' target='_newWindow'>1</a>\]</b>
	<br>
	<b>BULLETS</b> are lines with 3 spaces, an asterisk, a space - the item
	must be one (wrapped) line
	<br>
	<b>NUMBERED LISTS</b> are lines with 3 spaces, a one, a dot, a space - the item
	must be one (wrapped) line
	<br>
	<b>PARAGRAPHS</b> are split with empty lines,
	<b>UNFORMATTED TEXT </b>starts with white space
	<br>
	<b>HIGHLIGHTS</b> are indicated by groups of single quotes - use two for
	<b>''</b><i>italics</i><b>''</b>, three for <b>'''bold'''</b>
	<br>
	<b>SECTIONS</b> can be separated with a horizontal line - insert a line
	containing just 4 dashes
	</font></blockquote><hr size=1>
    }

    variable maxAge "next month"	;# maximum age of login cookie
    variable cookie "wikit"		;# name of login cookie

    # page sent to enable login
    variable login {title: login

	<p>You must have a nickname to post here</p>
	<form action='/_login' method='post'>
	<fieldset><legend>Login</legend>
	<label for='nickname'>Nickname </label><input type='text' name='nickname'><input type='submit' value='login'>
	</fieldset>
	<input type='hidden' name='R' value='[armour $R]'>
	</form>
    }

    # page sent when a browser sent bad utf8
    variable badutf {title: bad UTF-8

	<h2>Encoding error on page $N - [Ref $N $name]</h2>
	<p><bold>Your changes have NOT been saved</bold>,
	because	the content your browser sent contains bogus characters.
	At character number $point.</p>
	<p><italic>Please check your browser.</italic></p>
	<hr size=1 />
	<p><pre>[armour $C]</pre></p>
	<hr size=1 />
    }

    # page sent when a save causes edit conflict
    variable conflict {title: Edit Conflict on $N

	<h2>Edit conflict on page $N - [Ref $N $name]</h2>
	<p><bold>Your changes have NOT been saved</bold>,
	because	someone (at IP address $who) saved
	a change to this page while you were editing.</p>
	<p><italic>Please restart a new [Ref /_edit/$N edit]
	and merge your version,	which is shown in full below.</italic></p>
	<p>Got '$O' expected '$X'</p>
	<hr size=1 />
	<p><pre>[armour $C]</pre></p>
	<hr size=1 />
    }

    # converter from x-text/system to html-fragment
    # arranges for headers metadata
    proc .x-text/system.x-x-text/html-fragment {rsp} {
	# split out headers
	set headers ""
	set body [split [string trimleft [dict get $rsp -content] \n] \n]
	set start 0
	set headers {}

	foreach line $body {
	    set line [string trim $line]
	    if {[string match <* $line]} break

	    incr start
	    if {$line eq ""} continue

	    # this is a header line
	    set val [lassign [split $line :] tag]
	    dict lappend rsp -headers "<$tag>[string trim [join $val]]</$tag>"
	    Debug.convert {.x-text/system.x-text/html-fragment '$tag:$val' - $start}
	}

	set content "[join [lrange $body $start end] \n]\n"

	return [dict replace $rsp \
		    -content $content \
		    content-type x-text/html-fragment]
    }

    variable htmlhead {<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">}
    variable language "en"	;# language for HTML

    # header sent with each page
    #<meta name='robots' content='index,nofollow' />
    variable head {
	<style type='text/css' media='all'>@import url(/wikit.css);</style>
	<link rel='alternate' type='application/rss+xml' title='RSS' href='/rss.xml'>
    }

    # convertor for x-html-fragment to html
    proc .x-text/html-fragment.text/html {rsp} {
	set rspcontent [dict get $rsp -content]

	if {[string match "<!DOCTYPE*" $rspcontent]} {
	    # the content is already fully HTML
	    set content $rspcontent
	} else {
	    variable htmlhead
	    set content "${htmlhead}\n"

	    variable language
	    append content "<html lang='$language'>" \n

	    append content <head> \n
	    if {[dict exists $rsp -headers]} {
		append content [join [dict get $rsp -headers] \n] \n
		dict unset rsp -headers
	    }

	    # add in some wikit-wide headers
	    variable head
	    variable protected
	    append content $head

	    append content </head> \n

	    append content <body> \n
	    append content $rspcontent
	    append content [Honeypot link /$protected(HoneyPot)]
	    append content </body> \n
	    append content </html> \n
	}

	return [dict replace $rsp \
		    -content $content \
		    -raw 1 \
		    content-type text/html]
    }

    proc /state {r} {
	set state [::thread::send $::thread::parent {Httpd state}]
	set result "<table border='1'>\n"
	append result <tr><th> [join {socket thread backend ip conflict start end log} </th><th>] </th></tr> \n
	foreach row $state {
	    append result <tr><td> [join $row </td><td>] </td></tr> \n
	}
	append result </table> \n

	return [Http NoCache [Http Ok $r $result]]
    }

    proc /activity {r {L "current"} {F "html"} args} {
	# generate an activity page
	if {$L eq "log"} {
	    set act [::thread::send $::thread::parent {Httpd activity_log}]
	} else {
	    set act [::thread::send $::thread::parent {Httpd activity_current}]
	}

	switch -- $F {
	    csv {
		package require csv
		foreach a $act {
		    append result [::csv::joinlist $a] \n
		}
		dict set r content-type text/plain
	    }

	    html -
	    default {
		set result "<table border='1'>\n"
		dict set r content-type text/html
		append result <tr><th> [join [lindex $act 0] </th>\n<th>] </th></tr> \n
		foreach a [lrange $act 1 end] {
		    append result <tr><td> [join $a </td>\n<td>] </td></tr> \n
		}
		append result </table>
	    }
	}

	return [Http NoCache [Http Ok $r $result]]
    }

    # Special page: Recent Changes.
    variable delta [subst \u0394]
    proc RecentChanges {} {
	variable delta
	set count 0
	set results {}
	set lastDay 0
	set threshold [expr {[clock seconds] - 7 * 86400}]
	set deletesAdded 0

	foreach id [mk::select wdb.pages -rsort date] {
	    set result ""
	    lassign [mk::get wdb.pages!$id date name who page] date name who page
	    
	    # these are fake pages, don't list them
	    if {$id == 2 || $id == 4} continue

	    # skip cleared pages
	    if {[string length $name] == 0 || [string length $page] <= 1} continue

	    # only report last change to a page on each day
	    set day [expr {$date/86400}]

	    #insert a header for each new date
	    incr count
	    if {$day != $lastDay} {

		if { $lastDay && !$deletesAdded } { 
		    lappend results </ul>\n<ul>
		    lappend results [<li> [<a> href /_cleared "Cleared pages (title and/or page)"]]
		    set deletesAdded 1
		}

		# only cut off on day changes and if over 7 days reported
		if {$count > 100 && $date < $threshold} {
		    break
		}
		
		set lastDay $day
		if {$lastDay} {
		    lappend results </ul>
		}
		lappend results [<p> [<b> [clock format $date -gmt 1 -format {%B %e, %Y}]]]
		lappend results <ul>
	    }

	    append result [<a> href /$id $name]
	    append result [<span> class dots ". . ."]
	    append result [<span> class nick $who]
	    append result [<a> class delta href /_diff/$id#diff0 $delta]
	    
	    lappend results [<li> $result]
	}
	lappend result </ul>

	if {$count > 100 && $date < $threshold} {
	    lappend results [<p> "Older entries omitted..."]
	}

	return [join $results \n]
    }

    proc /cleared { r } {
	set results "<h1>Cleared pages</h1>"
	lappend results <ul>
	set count 0
	set lastDay 0
	foreach id [mk::select wdb.pages -rsort date] {
	    lassign [mk::get wdb.pages!$id date name who page] date name who page

	    # these are fake pages, don't list them
	    if {$id == 2 || $id == 4} continue

	    # skip pages with contents in both name and page
	    if {[string length $name] && [string length $page] > 1} continue

	    # skip pages with date 0
	    if { $date == 0 } continue

	    set day [expr {$date/86400}]

	    if { $day != $lastDay } {
		set lastDay $day
		if {$lastDay} {
		    lappend results </ul>
		}
		lappend results [<p> [<b> [clock format $date -gmt 1 -format {%B %e, %Y}]]]
		lappend results <ul>		
	    }

	    if { [string length $name] } {
		set link [<a> href /$id $name]
	    } else {
		set link [<a> href /$id $id]
	    }
	    append link [<span> class dots ". . ."]
	    append link [<span> class nick $who]
	    append link [<span> class dots ". . ."]
	    append link [<a> class delta href /_history/$id history]
	    lappend results [<li> $link]
	    incr count
	    if { $count >= 100 } {
		break
	    }
	}	
	if {$lastDay} {
	    lappend result </ul>
	}
	return [Http NoCache [Http Ok $r [join $results \n]]]
    }

    proc get_page_with_version {N V A} {
	if {$A} {
	    set aC [::Wikit::AnnotatePageVersion $N $V]
	    set C ""
	    set prevVersion -1
	    foreach a $aC {
		lassign $a line lineVersion time who
		if { $lineVersion != $prevVersion } {
		    if { $prevVersion != -1 } {
			append C "\n<<<<<<"
		    }
		    append C "\n>>>>>>a;$N;$lineVersion;$who;" [clock format $time -format "%Y-%m-%d %H:%M:%S UTC" -gmt true]
		    set prevVersion $lineVersion
		}
		append C "\n$line"
	    }
	    if { $prevVersion != -1 } {
		append C "\n<<<<<<"
	    }
	} elseif { $V >= 0 } {
	    set C [::Wikit::GetPageVersion $N $V]
	} else {
	    set C [GetPage $N]
	}
	return $C
    }

    proc wordlist { l } {
	set rl [split [string map {\  \0\  \n \ \n} $l] " "]
    }

    proc shiftNewline { s m } {
	if { [string index $s end] eq "\n" } {
	    return "$m[string range $s 0 end-1]$m\n"
	} else {
	    return "$m$s$m"
	}
    }

    proc unWhiteSpace { t } { 
	set n {}
	foreach l $t {
	    # Replace all but leading white-space by single space
	    set tl [string trimleft $l]
	    set nl [string range $l 0 [expr {[string length $l] - [string length $tl] - 1 }]]
	    append nl [regsub -all {\s+} $tl " "]
	    lappend n $nl
	}
	return $n
    }

    proc /diff {r N {V -1} {D -1} {W 0}} {
	Debug.wikit {/diff $args}

	set ext [file extension $N]	;# file extension?
	set N [file rootname $N]	;# it's a simple single page

	if {![string is integer -strict $N]
	    || ![string is integer -strict $V]
	    || ![string is integer -strict $D]
            || $N < 0
	    || $N >= [mk::view size wdb.pages]
	    || $ext ni {"" .txt .tk .str}
	} {
	    return [Http NotFound $r]
	}

	set nver [expr {1 + [mk::view size wdb.pages!$N.changes]}]
	if { $V >= $nver || $D >= $nver } {
	    return [Http NotFound $r]
	}

	if {$V < 0} {
	    set V [expr {$nver - 1}]	;# default
	}
	if {$D < 0} {
	    set D [expr {$nver - 2}]	;# default
	}

	Wikit::pagevars $N pname

	set t1 [split [get_page_with_version $N $V 0] "\n"]
	if {!$W} { set uwt1 [unWhiteSpace $t1] } else { set uwt1 $t1 }
	set t2 [split [get_page_with_version $N $D 0] "\n"]
	if {!$W} { set uwt2 [unWhiteSpace $t2] } else { set uwt2 $t2 }
	set p1 0
	set p2 0
	set C ""
	foreach {l1 l2} [::struct::list::LlongestCommonSubsequence $uwt1 $uwt2] {
	    foreach i1 $l1 i2 $l2 {
		if { $W && $p1 < $i1 && $p2 < $i2 } {
		    set d1 ""
		    set d2 ""
		    set pd1 0
		    set pd2 0
		    while { $p1 < $i1 } { 
			append d1 "[lindex $t1 $p1]\n"
			incr p1
		    }
		    while { $p2 < $i2 } { 
			append d2 "[lindex $t2 $p2]\n"
			incr p2
		    }
		    set d1 [wordlist $d1]
		    set d2 [wordlist $d2]
		    foreach {ld1 ld2} [::struct::list::LlongestCommonSubsequence $d1 $d2] {
			foreach id1 $ld1 id2 $ld2 {
			    while { $pd1 < $id1 } { 
				set w [lindex $d1 $pd1]
				if { [string length $w] } { 
				    append C [shiftNewline $w "^^^^"]
				}
				incr pd1
			    }
			    while { $pd2 < $id2 } {
				set w [lindex $d2 $pd2]
				if { [string length $w] } {
				    append C [shiftNewline $w "~~~~"]
				}
				incr pd2
			    }
			    append C "[lindex $d1 $id1]"
			    incr pd1
			    incr pd2
			}
			while { $pd1 < [llength $d1] } { 
			    set w [lindex $d1 $pd1]
			    if { [string length $w] } { 
				append C [shiftNewline $w "^^^^"]
			    }
			    incr pd1
			}
			while { $pd2 < [llength $d2] } { 
			    set w [lindex $d2 $pd2]
			    if { [string length $w] } {
				append C [shiftNewline $w "~~~~"]
			    }
			    incr pd2
			}
		    }
		} else {
		    while { $p1 < $i1 } { 
			append C ">>>>>>n;$N;$V;;\n[lindex $t1 $p1]\n<<<<<<\n"
			incr p1
		    }
		    while { $p2 < $i2 } { 
			append C ">>>>>>o;$N;$D;;\n[lindex $t2 $p2]\n<<<<<<\n"
			incr p2
		    }
		}
		if { [string equal [lindex $t1 $i1] [lindex $t2 $i2]] } {
		    append C "[lindex $t1 $i1]\n"
		} else {
		    append C ">>>>>>w;$N;$V;;\n[lindex $t1 $i1]\n<<<<<<\n"
		}
		incr p1
		incr p2
	    }
	}
	while { $p1 < [llength $t1] } { 
	    append C ">>>>>>n;$N;$V;;\n[lindex $t1 $p1]\n<<<<<<\n"
	    incr p1
	}
	while { $p2 < [llength $t2] } { 
	    append C ">>>>>>o;$N;$V;;\n[lindex $t2 $p2]\n<<<<<<\n"
	    incr p2
	}

	if { $W } {
	    set C [regsub -all "\0" $C " "]
	}

	set menu {}
	if {$V >= 0} {
	    switch -- $ext {
		.txt {
		    return [Http NoCache [Http Ok $r $C text/plain]]
		}
		.tk {
		    set Title "<h1>Difference between version $V and $D for [Ref $N]</h1>"
		    set name "Difference between version $V and $D for $pname"
		    set C [::Wikit::TextToStream $C]
		    lassign [::Wikit::StreamToTk $C ::WikitWub::InfoProc] C U
		    append result "<p>$C"
		}
		.str {
		    set C [::Wikit::TextToStream $C]
		    return [Http NoCache [Http Ok $r $C text/plain]]
		}
		default {
		    set Title "<h1>Difference between version $V and $D for [Ref $N]</h1>"
		    set name "Difference between version $V and $D for $pname"
		    if { $W } {
			set C [::Wikit::ShowDiffs $C]
		    } else {
			lassign [::Wikit::StreamToHTML [::Wikit::TextToStream $C] / ::WikitWub::InfoProc] C U T
		    }
		    set tC "<span class='newwikiline'>Text added in version $V is highlighted like this</span>, <span class='oldwikiline'>text deleted from version $D is highlighted like this</span>"
		    if {!$W} { append tC ", <span class='whitespacediff'>text with only white-space differences is highlighted like this</span>" }
		    set C "$tC<hr><p>$C"
		}
	    }
	}

	set menu {}
	variable protected
	variable menus
	foreach m {Search Changes About Home Help} {
	    lappend menu $menus($protected($m))
	}
	variable pageT
	return [Http NoCache [Http Ok $r [subst $pageT] x-text/system]]
    }

    proc /revision {r N {V -1} {A 0}} {
	Debug.wikit {/page $args}

	set ext [file extension $N]	;# file extension?
	set N [file rootname $N]	;# it's a simple single page

	if {![string is integer -strict $N]
	    || ![string is integer -strict $V]
	    || ![string is integer -strict $A]
            || $N < 0
	    || $N >= [mk::view size wdb.pages]
	    || $V < 0
	    || $ext ni {"" .txt .tk .str}
	} {
	    return [Http NotFound $r]
	}

	set nver [expr {1 + [mk::view size wdb.pages!$N.changes]}]
	if {$V >= $nver} {
	    return [Http NotFound $r]
	}

	Wikit::pagevars $N pname
	set menu {}
	if {$V >= 0} {
	    switch -- $ext {
		.txt {
		    set C [get_page_with_version $N $V $A]
		    return [Http NoCache [Http Ok $r $C text/plain]]
		}
		.tk {
		    set Title "<h1>Version $V of [Ref $N]</h1>"
		    set name "Version $V of $pname"
		    set C [::Wikit::TextToStream [get_page_with_version $N $V $A]]
		    lassign [::Wikit::StreamToTk $C ::WikitWub::InfoProc] C U
		    append result "<p>$C"
		}
		.str {
		    set C [::Wikit::TextToStream [get_page_with_version $N $V $A]]
		    return [Http NoCache [Http Ok $r $C text/plain]]
		}
		default {
		    if { [catch {get_page_with_version $N $V $A} C] } {
			return [Http NotFound $r]
		    } else {
			if {$A} {
			    set Title "<h1>Annotated version $V of [Ref $N]</h1>"
			    set name "Annotated version $V of $pname"
			} else {
			    set Title "<h1>Version $V of [Ref $N]</h1>"
			    set name "Version $V of $pname"
			}
			lassign [::Wikit::StreamToHTML [::Wikit::TextToStream $C] / ::WikitWub::InfoProc] C U T
			if { $V > 0 } {
			    lappend menu [Ref /_revision/$N?V=[expr {$V-1}]&A=$A "Previous version"]
			}
			if { $V < ($nver-1) } {
			    lappend menu [Ref /_revision/$N?V=[expr {$V+1}]&A=$A "Next version"]
			}
			lappend menu [Ref /_revision/$N?V=[expr {$nver-1}]&A=[expr {!$A}] Current]
		    }
		}
	    }
	}

	variable protected
	variable menus
	foreach m {Search Changes About Home Help} {
	    lappend menu $menus($protected($m))
	}

	variable pageT
	return [Http NoCache [Http Ok $r [subst $pageT] x-text/system]]
    }

    # /history - revision history
    proc /history {r N {S 0} {L 25}} {
	Debug.wikit {/history $N $S $L}
	if {![string is integer -strict $N]
	    || ![string is integer -strict $S]
	    || ![string is integer -strict $L]
	    || $N >= [mk::view size wdb.pages]
	    || $S < 0
	    || $L <= 0} {
	    return [Http NotFound $r]
	}

	set result "<h2>Change history of [Ref $N]</h2>"
	set links ""
	set nver [expr {1 + [mk::view size wdb.pages!$N.changes]}]
	if {$S > 0} {
	    set pstart [expr {$S - $L}]
	    if {$pstart < 0} {
		set pstart 0
	    }
	    append links [<a> href $N?S=$pstart&L=$L "Previous $L"]
	}
	set nstart [expr {$S + $L}]
	if {$nstart < $nver} {
	    if {$links ne {}} {
		append links { - }
	    }
	    append links [<a> href $N?S=$nstart&L=$L "Next $L"]
	}
	if {$links ne {}} {
	    append result <p> $links </p> \n
	}
	if {[catch {Wikit::ListPageVersionsDB wdb $N $L $S} versions]} {
	    append result <pre> $versions </pre>
	} else {
	    Wikit::pagevars $N name
	    append result "<table class='history'>\n<tr>"
	    foreach {column span} {{Revision} 1 {Date} 1 {Modified By} 1 {Line compare with} 3 {Word compare with} 3 Annotated 1 WikiText 1} {
		append result [<th> colspan $span $column]
	    }
	    append result </tr>\n
	    foreach row $versions {
		lassign $row vn date who
		set prev [expr {$vn-1}]
		set next [expr {$vn+1}]
		set curr [expr {$nver-1}]
		append result <tr>
		append result [<td> [<a> href /_revision/$N?V=$vn rel nofollow $vn]]
		append result [<td> [clock format $date -format "%Y-%m-%d %H:%M:%S UTC" -gmt true]]
		append result [<td> $who]

		if { $prev >= 0 } {
		    append result [<td> [<a> href /_diff/$N?V=$vn&D=$prev#diff0 "$prev"]]
		} else {
		    append result <td></td>
		}
		if { $next < $nver } {
		    append result [<td> [<a> href /_diff/$N?V=$vn&D=$next#diff0 "$next"]]
		} else {
		    append result <td></td>
		}
		if { $vn != $curr } {
		    append result [<td> [<a> href /_diff/$N?V=$curr&D=$vn#diff0 "Current"]]		
		} else {
		    append result <td></td>
		}

		if { $prev >= 0 } {
		    append result [<td> [<a> href /_diff/$N?V=$vn&D=$prev&W=1#diff0 "$prev"]]
		} else {
		    append result <td></td>
		}
		if { $next < $nver } {
		    append result [<td> [<a> href /_diff/$N?V=$vn&D=$next&W=1#diff0 "$next"]]
		} else {
		    append result <td></td>
		}
		if { $vn != $curr } {
		    append result [<td> [<a> href /_diff/$N?V=$curr&D=$vn&W=1#diff0 "Current"]]		
		} else {
		    append result <td></td>
		}

		append result [<td> [<a> href /_revision/$N?V=$vn&A=1 $vn]]
		append result [<td> [<a> href /_revision/$N.txt?V=$vn $vn]]
		append result </tr> \n
	    }
	    append result </table> \n
	}
	append result <p> $links </p> \n

	variable protected
	variable menus
	set menu {}
	foreach m {Search Changes About Home} {
	    lappend menu $menus($protected($m))
	}
	append result [<p> id footer [join $menu { - }]]
	return [Http NoCache [Http Ok $r $result]]
    }

    # Ref - utility proc to generate an <A> from a page id
    proc Ref {url {name "" }} {
	if {$name eq ""} {
	    set page [lindex [file split $url] end]
	    if {[catch {
		set name [mk::get wdb.pages!$page name]
	    }]} {
		set name $page
	    }
	}
	return [<a> href /[string trimleft $url /] $name]
    }

    variable protected
    variable menus
    array set protected {Home 0 About 1 Search 2 Help 3 Changes 4 HoneyPot 5 TOC 8 Init 9}
    foreach {n v} [array get protected] {
	set protected($v) $n
	set menus($v) [Ref $v $n]
    }

    set redir {meta: http-equiv='refresh' content='10;url=$url'

	<h1>Redirecting to $url</h1>
	<p>$content</p>
    }

    proc redir {r url content} {
	variable redir
	return [Http NoCache [Http SeeOther $r $url [subst $redir]]]
    }

    proc /login {r {nickname ""} {R ""}} {
	# cleanse nickname
	regsub -all {[^A-Za-z0-0_]} $nickname {} nickname

	if {$nickname eq ""} {
	    # this is a call to /login with no args,
	    # in order to generate the /login page
	    set R [Http Referer $r]
	    variable login;
	    return [Http NoCache [Http Ok $r [subst $login] x-text/system]]
	}

	if {[dict exists $r -cookies]} {
	    set cdict [dict get $r -cookies]
	} else {
	    set cdict [dict create]
	}
	set dom [dict get $r -host]

	# include an optional expiry age
	variable maxAge
	if {![string is integer -strict $maxAge]} {
	    if {[catch {
		expr {[clock scan $maxAge] - [clock seconds]}
	    } maxAge]} {
		set age {}
	    } else {
		set age [list -max-age $maxAge]
	    }
	}

	if {$maxAge} {
	    #set age [list -max-age $maxAge]
	    set then [expr {$maxAge + [clock seconds]}]
	    set age [clock format $then -format "%a, %d-%b-%Y %H:%M:%S GMT" -gmt 1]
	    set age [list -expires $age]
	} else {
	    set age {}
	}

	variable cookie
	#set cdict [Cookies add $cdict -path / -name $cookie -value $nickname {*}$age]
	set cdict [Cookies add $cdict -path / -name $cookie -value $nickname {*}$age]
	dict set r -cookies $cdict
	if {$R eq ""} {
	    set R [Http Referer $r]
	    if {$R eq ""} {
		set R "http://[dict get $r host]/0"
	    }
	}

	return [redir $r $R [<a> href $R "Created Account"]]
    }

    proc who {r} {
	variable cookie
	set cdict [dict get $r -cookies]
	set cl [Cookies match $cdict -name $cookie]
	if {[llength $cl] != 1} {
	    return ""
	}
	return [dict get [Cookies fetch $cdict -name $cookie] -value]
    }

    proc invalidate {r url} {
	Debug.wikit {invalidating $url} 3
	::thread::send -async $::thread::parent [list Cache delete http://[dict get $r host]/$url]
    }

    proc locate {page {exact 1}} {
	Debug.wikit {locate '$page'}
	variable cnt

	# try exact match on page name
	if {[string is integer -strict $page]} {
	    Debug.wikit {locate - is integer $page}
	    return $page
	}

	set N [mk::select wdb.pages name $page -min date 1]
	switch [llength $N] {
	    1 {
		# uniquely identified, done
		Debug.wikit {locate - unique by name - $N}
		return $N
	    }

	    0 {
		# no match on page name,
		# do a glob search over names,
		# where AbCdEf -> *[Aa]b*[Cc]d*[Ee]f*
		# skip this if the search has brackets (WHY?)
		if {[string first {[} $page] < 0} {
		    regsub -all {[A-Z]} $page {*\\[&[string tolower &]\]} temp
		    set temp "[subst -novariable $temp]*"
		    set N [mk::select wdb.pages -glob name $temp -min date 1]
		}
		if {[llength $N] == 1} {
		    # glob search was unambiguous
		    Debug.wikit {locate - unique by title search - $N}
		    return $N
		}
	    }
	}

	# ambiguous match or no match - make it a keyword search
	set ::Wikit::searchLong [regexp {^(.*)\*$} $page x ::Wikit::searchKey]
	Debug.wikit {locate - kw search}
	return 2	;# the search page

	# these two globals (searchKey and searchLong) control the
	# representation of page 2 - they will cause it to return
	# a list of matches
    }

    proc /search {r {S ""} args} {
	if {$S eq "" && [llength $args] > 0} {
	    set S [lindex $args 0]
	}

	Debug.wikit {/search: '$S'}
	dict set request -suffix $S
	dict set request -prefix "/$S"

	set ::Wikit::searchLong [regexp {^(.*)\*$} $S x ::Wikit::searchKey]
	return [WikitWub do $r 2]
    }

    proc /save {r N C O save} {
	variable readonly; variable roT
	if {$readonly ne ""} {
	    return [Http NoCache [Http Ok $r [subst $roT] x-text/system]]
	}

	if {![string is integer -strict $N]} {
	    return [Http NotFound $r]
	}
	if {$N >= [mk::view size wdb.pages]} {
	    return [Http NotFound $r]
	}

	if {[catch {
	    ::Wikit::pagevars $N name date who
	} er eo]} {
	    return [Http NotFound $er "<h2>$N is not a valid page.</h2>
		<p>[armour $r]([armour $eo])</p>"]
	}

	# is the caller logged in?
	set nick [who $r]
	set when [expr {[dict get $r -received] / 1000000}]
	Debug.wikit {/save who: $nick $when - modified:"$date $who" O:$O }

	# if there is new page content, save it now
	variable protected
	if {$N ne ""
	    && $C ne ""
	    && ![info exists protected($N)]
	} {
	    # added 2002-06-13 - edit conflict detection
	    if {$O ne [list $date $who]} {
		#lassign [split [lassign $O ewhen] @] enick eip
		if {$who eq "$nick@[dict get $r -ipaddr]"} {
		    # this is a ghostly conflict-with-self - log and ignore
		    Debug.error "Conflict on Edit of $N: '$O' ne '[list $date $who]' at date $when"
		    set url http://[dict get $r host]/$N
		    return [redir $r $url [<a> href $url "Edited Page"]]
		} else {
		    set X [list $date $who]
		    variable conflict
		    return [Http NoCache [Http Conflict $r [subst $conflict]]]
		}
	    }

	    # newline-normalize content
	    set C [string map {\r\n \n \r \n} $C]

	    # check the content for utf8 correctness
	    # this metadata is set by Query parse/cconvert
	    set point [Dict get? [Query metadata [dict get $r -Query] C] -bad]
	    if {$point ne "" 
		&& $point < [string length $C] - 1
	    } {
		if {$point >= 0} {
		    incr point
		    binary scan [string index $C $point] H* bogus
		    set C [string replace $C $point $point "<BOGUS 0x$bogus>"]
		}
		variable badutf
		return [Http NoCache [Http Ok $r [subst $badutf] x-text/system]]
	    }

	    # Only actually save the page if the user selected "save"
	    if {$save eq "Save" && $nick ne ""} {
		invalidate $r $N
		invalidate $r 4
		invalidate $r _ref/$N
		invalidate $r rss.xml

		# if this page did not exist before:
		# remove all referencing pages.
		#
		# this makes sure that cache entries point to a filled-in page
		# from now on, instead of a "[...]" link to a first-time edit page
		if {$date == 0} {
		    foreach from [mk::select wdb.refs to $N] {
			invalidate $r [mk::get wdb.refs!$from from]
		    }
		}

		set who $nick@[dict get $r -ipaddr]
		::Wikit::SavePage $N [string map {"Robert Abitbol" unperson} $C] $who $name $when
	    }
	}
	set url http://[dict get $r host]/$N
	return [redir $r $url [<a> href $url "Edited Page"]]
    }

    proc GetPage {id} {
	return [mk::get wdb.pages!$id page]
    }

    # /reload - direct url to reload numbered pages from fs
    proc /reload {r} {
	foreach {} {}
    }

    # called to generate an edit page
	proc /edit {r N args} {
	variable readonly; variable roT
	if {$readonly ne ""} {
	    return [Http NoCache [Http Ok $r [subst $roT] x-text/system]]
	}

	if {![string is integer -strict $N]} {
	    return [Http NotFound $r]
	}
	if {$N < 10} {
	    return [Http Forbidden $r]
	}
	if {$N >= [mk::view size wdb.pages]} {
	    return [Http NotFound $r]
	}

	# is the caller logged in?
	set nick [who $r]
	if {$nick eq ""} {
	    variable login
	    set R ""	;# make it return here
	    # TODO KBK: Perhaps allow anon edits with a CAPTCHA?
	    # Or at least give a link to the page that gets the cookie back.
	    return [Http NoCache [Http Ok $r [subst $login] x-text/system]]
	}

	::Wikit::pagevars $N name date who

	set who_nick ""
	regexp {^(.+)[,@]} $who - who_nick
	set C [armour [GetPage $N]]
	if {$C eq ""} {set C "empty"}

	variable edit; set result [subst $edit]
	
	if {$date != 0} {
	    append result "<italic>Last saved on <bold>[clock format $date -gmt 1 -format {%e %b %Y, %R GMT}]</bold></italic>"
	}
	if {$who_nick ne ""} {
	    append result "<italic> by <bold>$who_nick</bold></italic>"
	}
	if {$nick ne ""} {
	    append result " (you are: <bold>$nick</bold>)"
	}

	return [Http NoCache [Http Ok $r $result x-text/system]]
    }

    proc /motd {r} {
	variable motd
	catch {set motd [::fileutil::cat [file join $::config(docroot) motd]]}
	set motd [string trim $motd]

	invalidate $r 4	;# make the new motd show up

	set R [Http Referer $r]
	if {$R eq ""} {
	    set R http://[dict get $r host]/4
	}
	return [redir $r $R [<a> href $R "Loaded MOTD"]]
    }

	# called to generate a page with references
    proc /ref {r N} {
	#set N [dict get $r -suffix]
	Debug.wikit {/ref $N}
	if {![string is integer -strict $N]} {
	    return [Http NotFound $r]
	}
	if {$N >= [mk::view size wdb.pages]} {
	    return [Http NotFound $r]
	}

	set refList ""
	foreach from [mk::select wdb.refs to $N] {
	    set from [mk::get wdb.refs!$from from]
	    ::Wikit::pagevars $from name
	    lappend refList [list $name $from]
	}

	# the items are a list, if we would just sort on them, then all
	# single-item entries come first (the rest has {}'s around it)
	# the following sorts again on 1st word, knowing sorts are stable

	set refList [lsort -dict -index 0 [lsort -dict $refList]]
	set C "<ul>"
	foreach x $refList {
	    lassign $x name from
	    ::Wikit::pagevars $from who date
	    append C <li>[::Wikit::GetTimeStamp $date]
	    append C " . . . [Ref $from] . . . $who</li>"
	}
	append C "</ul>"

	variable protected
	variable menus
	set menu {}
	foreach m {Search Changes About Home} {
	    lappend menu $menus($protected($m))
	}
	variable refs; 
	return [Http Ok $r [subst $refs] x-text/system]
    }

    proc InfoProc {ref} {
	set id [::Wikit::LookupPage $ref wdb]
	::Wikit::pagevars $id date name

	if {$date == 0} {
	    set id _edit/$id ;# enter edit mode for missing links
	} else {
	    set id /$id	;# add a leading / which format.tcl will strip
	}

	return [list /$id $name $date]
    }

    proc search {key date} {
	Debug.wikit {search: '$key'}
	set long [regexp {^(.*)\*$} $key x key]
	set fields name
	if {$long} {
	    lappend fields page
	}

	if { $date == 0 } {
	    set rows [mk::select wdb.pages -rsort date -keyword $fields $key]
	} else {
	    set rows [mk::select wdb.pages -max date $date -rsort date -keyword $fields $key]
	}

	# tclLog "SearchResults key <$key> long <$searchLong>"
	set tcount 0
	set rdate $date
	set count 0
	set result "Searched for \"'''$key'''\" (in page titles"
	if {$long} {
	    append result { and contents}
	}
	append result "):\n\n"

	foreach i $rows {
	    incr tcount
	    # these are fake pages, don't list them
	    if {$i == 2 || $i == 4 || $i == 5} continue

	    ::Wikit::pagevars $i date name
	    if {$date == 0} continue	;# don't list empty pages

	    # ignore "near-empty" pages with at most 1 char, 30-09-2004
	    if {[mk::get wdb.pages!$i -size page] <= 1} continue

	    append result "   * [::Wikit::GetTimeStamp $date] . . . \[$name\]\n"
	    set rdate $date

	    incr count
	    if {$count >= 100} {
		#append result "''Remaining [expr {[llength $rows] - 100}] matches omitted...''"
		break
	    }
	}
	
	if {$count == 0} {
	    append result "   * '''''No matches found'''''\n"
	    set rdate 0
	} else {
	    append result "   * ''Displayed $count matches''\n"
	    if {[llength $rows] > $tcount} {
		append result "   * ''Remaining [expr {[llength $rows] - $tcount}] matches omitted...''\n"
	    } else {
		set rdate 0
	    }
	}
	
	if {!$long} {
	    append result "\n''Tip: append an asterisk to search the page contents as well as titles.''"
	}

	return [list $result $rdate]
    }

    variable trailers {@ _edit ! _ref - _diff + _history}
    proc do {r term} {
	# decompose name
	set N [file rootname $term]	;# it's a simple single page
	set ext [file extension $term]	;# file extension?

	# strip fancy terminator shortcuts off end
	set fancy [string index $N end]
	if {$fancy in {@ ! - +}} {
	    set N [string range $N 0 end-1]
	} else {
	    set fancy ""
	}

	# handle searches
	if {![string is integer -strict $N]} {
	    set N [locate $term]
	    if {$N == "2"} {
		# locate has given up - can't find a page - go to search
		return [Http Redirect $r "http://[dict get $r host]/2" "" "" S [Query decode $term$fancy]]
	    } elseif {$N ne $term} {
		# we really should redirect
		return [Http Redirect $r "http://[dict get $r host]/$N"]
	    }
	}

	# term is a simple integer - a page number
	if {$fancy ne ""} {
	    variable trailers
	    # we need to redirect to the appropriate spot
	    set url [dict get $trailers $fancy]/$N
	    return [Http Redirect $r "http://[dict get $r host]/$url"]
	}

	set date [clock seconds]	;# default date is now
	set name ""	;# no default page name
	set who ""	;# no default editor
	set cacheit 1	;# default is to cache

	switch -- $N {
	    2 {
		# search page
		set qd [Dict get? $r -Query]
		if {[Query exists $qd S]
		    && [set term [Query value $qd S]] ne ""
		} {
		    # search page with search term supplied
		    set search "value='[armour $term]'"

		    # determine search date
		    if {[Query exists $qd F]} {
			set qdate [Query value $qd F]
			if {![string is integer -strict $qdate]} {
			    set qdate 0
			}
		    } else {
			set qdate 0
		    }

		    lassign [search $term $qdate] C nqdate
		    set C [::Wikit::TextToStream $C]
		    lassign [::Wikit::StreamToHTML $C / ::WikitWub::InfoProc] C U
		    if { $nqdate } {
			append C "<p><a href='/_search?S=[armour $term]&F=$nqdate'>More search results...</a></p>"
		    }
		} else {
		    # send a search page
		    set search ""
		    set C ""
		}

		variable searchT; set C [subst $searchT]
		set name "Search"
		set cacheit 0	;# don't cache searches
	    }

	    4 {
		# Recent Changes page
		variable motd
		set C "${motd}[RecentChanges]"
		set name "Recent Changes"
	    }

	    default {
		# simple page - non search term
		if {$N >= [mk::view size wdb.pages]} {
		    return [Http NotFound $r]
		}
		# set up a few standard URLs an strings
		if {[catch {::Wikit::pagevars $N name date who}]} {
		    return [Http NotFound $r]
		}
		# fetch page contents
		switch -- $ext {
		    .txt {
			set C [GetPage $N]
			return [Http NoCache [Http Ok $r $C text/plain]]
		    }
		    .tk {
			set C [::Wikit::TextToStream [GetPage $N]]
			lassign [::Wikit::StreamToTk $C ::WikitWub::InfoProc] C U T
		    }
		    .str {
			set C [::Wikit::TextToStream [GetPage $N]]
			return [Http NoCache [Http Ok $r $C text/plain]]
		    }
		    default {
			set C [::Wikit::TextToStream [GetPage $N]]
			lassign [::Wikit::StreamToHTML $C / ::WikitWub::InfoProc] C U T
		    }
		}
	    }
	}

	Debug.wikit {located: $N}

	# set up backrefs
	set refs [mk::select wdb.refs to $N]
	Debug.wikit {[llength $refs] backrefs to $N}
        switch -- [llength $refs] {
	    0 {
		set backRef ""
		set Refs ""
		set Title $name
	    }
	    1 {
		set backRef /_ref/$N
		set Refs "[Ref $backRef Reference] - "
		set Title [Ref $backRef $name]
	    }
	    default {
		set backRef /_ref/$N
		set Refs "[llength $refs] [Ref $backRef References]"
		set Title [Ref $backRef $name]
		Debug.wikit {backrefs: backRef:'$backRef' Refs:'$Refs' Title:'$Title'} 10
	    }
	}

	# arrange the page's tail
	set updated ""
	if {$date != 0} {
	    set update [clock format $date -gmt 1 -format {%e %b %Y, %R GMT}]
	    set updated "Updated $update"
	}

	if {$who ne "" &&
	    [regexp {^(.+)[,@]} $who - who_nick]
	    && $who_nick ne ""
	} {
	    append updated " by $who_nick"
	}
	set menu [list $updated]

	variable protected
	if {![info exists protected($N)]} {
	    if {!$::roflag} {
		lappend menu [Ref /_edit/$N Edit]
		lappend menu [Ref /_history/$N Revisions]
	    }
	}

	variable menus
	lappend menu "Go to [Ref 0]"
	foreach m {About Changes Help} {
	    if {$N != $protected($m)} {
		lappend menu $menus($protected($m))
	    }
	}

	set Title "<h1 class='title'>$Title</h1>"
	if {0} {
	    # get the page title
	    if {![regsub {^<p>(<img src=".*?")>} $C [Ref 0 $backRef] C]} {
		set Title "<h1 class='title'>$Title</h1>"
	    } else {
		set Title ""
	    }
	}

	variable readonly
	if {$readonly ne ""} {
	    set ro "<it>(Read Only Mode: $readonly)</it>"
	} else {
	    set ro ""
	}
	variable pageT
	set page [string trimleft [subst $pageT] \n]
	if {$cacheit} {
	    return [Http DCache [Http CacheableContent $r $date $page x-text/system]]
	} else {
	    return [Http NoCache [Http Ok $r $page x-text/system]]
	}
    }

    namespace export -clear *
    namespace ensemble create -subcommands {}
}

set roflag 0
if {$roflag} {
    proc WikitWub::/save {args} {
	return "<h2>Read Only</h2><p>Your changes have not been saved.</p>"
    }
}

proc do {args} {
    variable response
    variable request
    set code [catch {{*}$args} r eo]
    switch -- $code {
	1 {
	    set response [Http ServerError $request $r $eo]
	    return 1
	}
	default {
	    set response $r
	    if {$code == 0} {
		set code 200
	    }
	    if {![dict exists $response -code]} {
		dict set response -code $code
	    }
	    Debug.wikit {Response code: $code / [dict get $response -code]}
	    return 0
	}
    }
}

Direct wikit -namespace ::WikitWub -ctype "x-text/html-fragment"
Convert convert -namespace ::WikitWub

foreach {dom expiry} {css {tomorrow} images {next week} scripts {tomorrow} img {next week} html 0 bin 0} {
    File $dom -root [file join $config(docroot) $dom] -expires $expiry
}

catch {
    set ::WikitWub::motd [::fileutil::cat [file join $config(docroot) motd]]
}

# disconnected - courtesy indication
# we've been disconnected
proc Disconnected {args} {
    # we're pretty well stateless
}

proc incoming {req} {
    inQ put $req

    # some code to detect races (we hope)
    set chans [chan names sock*]
    set s [Dict get? $req -sock]
    if {[llength $chans] > 1
	|| ([llength $chans] > 0 && $s ne "" && $s ni $chans)
    } {
	Debug.error {RACE: new req from $s ($chans)}
    }

    variable response
    variable request
    while {([dict size $request] == 0)
	   && ([catch {inQ get} req eo] == 0)
       } {
	set request $req

	set path [dict get $request -path]
	dict set request -cookies [Cookies parse4server [Dict get? $request cookie]]

	# get a plausible prefix/suffix split
	Debug.wikit {incoming path: $path}
	set suffix [file join {} {*}[lassign [file split $path] -> fn]]
	dict set request -suffix $suffix
	dict set request -prefix "/$fn"
	Debug.wikit {invocation: fn:$fn suffix:$suffix}

	# check that this isn't a known bot
	if {[dict exists $request -bot] && $path ne "/_captcha"} {
	    Debug.wikit {Honeypot: it's a bot, and not /_captcha}
	    # Known bot: everything but /_captcha gets redirected to /_honeypot
	    if {
		$path eq "/$::WikitWub::protected(HoneyPot)"
		|| $path eq "/_honeypot"
	    } {
		Debug.wikit {Honeypot: it's a bot, and going to /_honeypot}
		set path /_honeypot
		dict set request -prefix $path
		dict set request -suffix _honeypot
		set fn _honeypot
	    } else {
		# redirect everything else to /_honeypot
		Debug.wikit {Honeypot: it's a bot, and we're redirecting to /_honeypot}
		set url "http://[dict get $request host]/_honeypot"
		set response [Http Relocated $request $url]
		dict set response -transaction [dict get $request -transaction]
		dict set response -generation [dict get $request -generation]
		::thread::send -async [dict get $request -worker] [list send $response]
		set request [dict create]	;# go idle
		continue	;# process next request
	    }
	} else {
	    # not a known bot, until it touches Honeypot
	    if {$path eq "/$::WikitWub::protected(HoneyPot)" || [pest $req]} {
		Debug.wikit {Honeypot: Triggered the Trap}
		# silent redirect to /_honeypot
		set path /_honeypot
		dict set request -prefix $path
		dict set request -suffix _honeypot
		set fn _honeypot
	    }
	}

	switch -glob -- $path {
	    /*.php -
	    /*.wmv -
	    /*.exe -
	    /cgi-bin/* {
		set ip [dict get $request -ipaddr]
		if {$ip eq "127.0.0.1"
		    && [dict exists $request x-forwarded-for]
		} {
		    set ip [lindex [split [dict get $request x-forwarded-for] ,] 0]
		}
		thread::send -async $::thread::parent [list Httpd block $ip "Bogus URL"]

		# send the bot a 404
		set response [Http NotFound $request]
		dict set response -transaction [dict get $request -transaction]
		dict set response -generation [dict get $request -generation]
		::thread::send -async [dict get $request -worker] [list send $response]
		set request [dict create]	;# go idle
		continue	;# process next request
	    }

	    /*.jpg -
	    /*.gif -
	    /*.png -
	    /favicon.ico {
		Debug.wikit {image invocation}
		# need to silently redirect image files
		set suffix [file join {} {*}[lrange [file split $path] 1 end]]
		dict set request -suffix $suffix
		dict set request -prefix "/images"
		do images do $request
	    }

	    /*.css {
		# need to silently redirect css files
		Debug.wikit {css invocation}
		set suffix [file join {} {*}[lrange [file split $path] 1 end]]
		dict set request -suffix $suffix
		dict set request -prefix "/css"
		do css do $request
	    }

	    /*.gz {
		# need to silently redirect gz files
		Debug.wikit {bin invocation}
		set suffix [file join {} {*}[lrange [file split $path] 1 end]]
		dict set request -suffix $suffix
		dict set request -prefix "/bin"
		do bin do $request
	    }

	    /robots.txt -
	    /*.js {
		# need to silently redirect js files
		Debug.wikit {script invocation}
		set suffix [file join {} {*}[lrange [file split $path] 1 end]]
		dict set request -suffix $suffix
		dict set request -prefix "/scripts"
		do scripts do $request
	    }

	    /_honeypot -
	    /_captcha {
		# handle the honeypot - either a bot has just fallen in,
		# or a known bot is being sent there.
		Debug.wikit {honeypot $path - $fn}
		dict set request -suffix [string trimleft $fn _]
		do ::honeypot do $request
	    }

	    /_motd -
	    /_edit/* -
	    /_save/* -
	    /_history/* -
	    /_revision/* -
	    /_diff/* -
	    /_ref/* -
	    /_cleared -
	    /_search/* -
	    /_search -
	    /_activity -
	    /_state -
	    /_login {
		# These are wiki-local restful command URLs,
		# we process them via the wikit Direct domain
		Debug.wikit {direct invocation}
		dict set request -suffix [string trimleft $fn _]
		set qd [Query add [Query parse $request] N $suffix]
		dict set request -Query $qd
		Debug.wikit {direct N: [Query value $qd N]}
		do wikit do $request
	    }

	    /rss.xml {
		# These are wiki-local restful command URLs,
		# we process them via the wikit Direct domain
		Debug.rss {rss invocation}
		set code [catch {WikitRss rss} r eo]
		Debug.rss {rss result $code ($eo)}
		switch -- $code {
		    1 {
			set response [Http ServerError $request $r $eo]
		    }

		    default {
			set response [Http CacheableContent $request [clock seconds] $r text/xml]
		    }
		}
	    }

	    / {
		# need to silently redirect welcome file
		Debug.wikit {welcome invocation}
		dict set request -suffix welcome.html
		dict set request -prefix /html
		do html do $request
	    }

	    //// {
		Debug.wikit {/ invocation}
		dict set request -suffix 0
		dict set request -Query [Query parse $request]
		do WikitWub do $request 0
	    }

	    default {
		Debug.wikit {default invocation}
		dict set request -suffix $fn
		dict set request -Query [Query parse $request]
		do WikitWub do $request $fn
	    }
	}

	# send response
	do convert do $response	;# convert page
	dict set response -transaction [dict get $request -transaction]
	dict set response -generation [dict get $request -generation]
	::thread::send -async [dict get $request -worker] [list send $response]
	set request [dict create]	;# go idle
    }
}

# fetch and initialize Wikit
package require Wikit::Format
#namespace import Wikit::Format::*
package require Wikit::Db
package require Wikit::Cache

set Wikit::mutex $config(mkmutex)	;# set mutex for wikit writes
Wikit::BuildTitleCache

set script [mk::get wdb.pages!9 page]
#puts stderr "Script: $script"
catch {eval $script}

# move utf8 regexp into utf8 package
# utf8 package is loaded by Query
set ::utf8::utf8re $config(utf8re); unset config(utf8re)

# initialize RSS feeder
WikitRss init wdb "Tcler's Wiki" http://wiki.tcl.tk/

Debug on log 10

Debug off query 10
Debug off wikit 10
Debug off direct 10
Debug off convert 10
Debug off cookies 10
Debug off socket 10
Debug on error 10

Debug.error {RESTART: [clock format [clock second]]}

catch {source [file join [file dirname [info script]] local.tcl]} r eo
Debug.log {LOCAL: '$r' ($eo)} 6

thread::wait
