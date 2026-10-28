window.electron = {
openExternal: function(lnk){window.open(lnk)},
openIDM: function(link){window.location.href=`intent:${link.replace(/^https?:/,'')}#Intent;scheme=https;package=com.dv.adm;end`},
eventOn: function(){console.log('no')},
openPotPlayer: function(link){window.location.href=link.replace('https://','potplayer://')}
}