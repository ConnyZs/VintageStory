In C:\Users\conny\AppData\Local\Temp\vsmodsync_5477.ps1:75 Zeichen:36
+   Say "Mods folder: $modsDir ($cnt mod(s) currently installed)" Green
+                                    ~~~
Unerwartetes Token "mod" in Ausdruck oder Anweisung.
In C:\Users\conny\AppData\Local\Temp\vsmodsync_5477.ps1:75 Zeichen:35
+   Say "Mods folder: $modsDir ($cnt mod(s) currently installed)" Green
+                                   ~
Schließende ")" fehlt in einem Ausdruck.
In C:\Users\conny\AppData\Local\Temp\vsmodsync_5477.ps1:75 Zeichen:62
+   Say "Mods folder: $modsDir ($cnt mod(s) currently installed)" Green
+                                                              ~
Unerwartetes Token ")" in Ausdruck oder Anweisung.
In C:\Users\conny\AppData\Local\Temp\vsmodsync_5477.ps1:80 Zeichen:6
+ Say "Loading server mod list..." Gray
+      ~~~~~~~
Unerwartetes Token "Loading" in Ausdruck oder Anweisung.
In C:\Users\conny\AppData\Local\Temp\vsmodsync_5477.ps1:87 Zeichen:27
+ Say ("Server: game v{0} | {1} mods" -f $man.game_version, $man.count) ...
+                           ~~~
Ausdrücke sind nur als erstes Element einer Pipeline zulässig.
In C:\Users\conny\AppData\Local\Temp\vsmodsync_5477.ps1:87 Zeichen:31
+ ... "Server: game v{0} | {1} mods" -f $man.game_version, $man.count) Cyan
+                              ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Unerwartetes Token "mods" -f $man.game_version, $man.count) Cyan
Say ""
# ---- game version check ----
if ($vsVerObj -and $man.game_version) {
  try {
    $srvVer = [Version]$man.game_version
    if ($srvVer -gt $vsVerObj) {
      Say ("Game" in Ausdruck oder Anweisung.
In C:\Users\conny\AppData\Local\Temp\vsmodsync_5477.ps1:206 Zeichen:36
+     $old = $installedIds[($m.modid ?? "").ToLower()]
+                                    ~~
Unerwartetes Token "??" in Ausdruck oder Anweisung.
In C:\Users\conny\AppData\Local\Temp\vsmodsync_5477.ps1:206 Zeichen:35
+     $old = $installedIds[($m.modid ?? "").ToLower()]
+                                   ~
Schließende ")" fehlt in einem Ausdruck.
In C:\Users\conny\AppData\Local\Temp\vsmodsync_5477.ps1:206 Zeichen:35
+     $old = $installedIds[($m.modid ?? "").ToLower()]
+                                   ~
"]" fehlt nach einem Arrayindexausdruck.
In C:\Users\conny\AppData\Local\Temp\vsmodsync_5477.ps1:204 Zeichen:30
+   foreach ($m in $optUpdate) {
+                              ~
Die schließende "}" fehlt im Anweisungsblock oder der Typdefinition.
Es wurden nicht alle Analysefehler berichtet. Korrigieren Sie die berichteten Fehler, und versuchen Sie es erneut.
    + CategoryInfo          : ParserError: (:) [], ParentContainsErrorRecordException
    + FullyQualifiedErrorId : UnexpectedToken


Drücken Sie eine beliebige Taste . . .
