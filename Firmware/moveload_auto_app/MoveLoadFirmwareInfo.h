#pragma once

// One definition of the firmware's identity, because two places need it and a
// drift between them fails silently:
//
//   - APPINFO_NAME in App.cpp, which is what the Movesense tooling reports.
//   - the HELLO response in GATTSensorDataClient, which is what MoveLoad reads
//     and compares against `MovesenseSensorService.autoFirmwareName` before
//     skipping the reboot on stopLogging(). A mismatch there restores the
//     reboot and quietly undoes every stop.
//
// /Info/App would have been the tidy source, but this device does not answer
// that resource — /Info does, which is why the serial arrives and the app name
// did not.
#define MOVELOAD_APP_NAME "MoveLoad Auto"
// Bump this on every image that goes onto a sensor. Two builds that differ in
// behaviour but report the same version cannot be told apart once flashed, and
// "which firmware is actually on it?" then has no answer short of reflashing.
//   1.0.0  first working GSP build
//   1.1.0  SUBSCRIBE answers; the link release spares an active GSP client
//   1.2.0  LED vocabulary: 1 blink strap noticed, 3 recording started,
//          5 recording stopped — the only way to observe the automatic stop
//   1.3.0  a pulse counts only if the R-R intervals move: a damp strap keeps
//          the heart rate service emitting a plausible average, which defeated
//          both the arming gate and the stop watchdog
//   1.4.0  the intervals must move *like a heart*: 1.3.0 only asked that they
//          move, and the damp strap's noise varies rather than freezing
//   1.5.0  the no-pulse stop falls from three minutes to one
//   1.6.0  UNSUBSCRIBE answers; no auto-start while a phone is on GSP, which
//          was restarting a recording in the middle of the HRV test
//   1.7.0  the same guard where it counts — at the moment logging starts, not
//          only when arming begins: the strap goes on before the app opens
//   1.8.0  2 blinks when arming gives up without finding a pulse. A session
//          that failed to start on someone else's chest left nothing at all
//          to look at: the steady light said the strap was noticed, and
//          silence afterwards meant either "still listening" or "gave up
//          twelve minutes ago", which are not the same problem
//   1.9.0  the external-stop inhibition is time-bounded. It was cleared only
//          by a loss of contact, which a damp strap suppresses indefinitely,
//          so the morning HRV test — which stops the recording the sensor had
//          started on its own — inhibited every recording for the rest of the
//          day, silently and with no LED
//   1.10.0 the GSP client flag is cleared when the BLE link drops. It was
//          only ever cleared by a CCCD write, which a dropped link does not
//          send — so the sensor went on believing a phone was using it and
//          refused to arm for good
//   1.11.0 the heart rate measurement is not taken away from a connected
//          phone, and arming stops declaring "no pulse" at an athlete who has
//          one. Arming cannot complete while a GSP client is connected, so on
//          a morning where the strap goes on before the app is opened, the
//          five-minute arming timeout lands in the middle of the HRV test: it
//          blinked the two-blink no-pulse code — the signal the auto-start is
//          read by — and unsubscribed /Meas/HR, the measurement the test is
//          made of, with the retry three minutes later blocked by that same
//          connected phone. On 2026-09-05 the test kept two minutes of the
//          lying position and nothing at all standing
//   1.12.0 la pause d'armement ne peut plus devenir un piège. L'identifiant
//          de minuteur sert à deux choses — la tentative de cinq minutes et
//          la pause de trois qui la suit — et c'est le drapeau de pause qui
//          choisit la branche à l'expiration. Une perte de contact effaçait
//          le drapeau sans arrêter le minuteur : l'expiration suivante était
//          alors lue comme une tentative sans pouls, clignotait le code à
//          deux éclats, remettait le drapeau et relançait une pause, sans
//          jamais armer. Rien n'abonne la fréquence cardiaque dans cet état,
//          donc aucun pouls ne peut venir en sortir, et chaque nouvelle perte
//          de contact renouvelait le piège — or une sangle prise, mouillée
//          puis portée perd le contact plusieurs fois avant d'atteindre une
//          poitrine. Le contact retrouvé arme désormais aussitôt
//   1.13.0 un journal des décisions, lisible par l'app sur /MoveLoad/State :
//          les seize dernières décisions d'armement avec leur âge, plus l'état
//          courant des drapeaux dont elles dépendent. Trois pannes de suite
//          ont eu la même forme — une machine à états où l'on ne peut plus
//          entrer — et chacune a coûté une journée de terrain, parce que de
//          l'extérieur elles se ressemblent toutes : pas de LED, pas de
//          séance, rien à lire
//   1.14.0 le journal passe à trente-deux entrées, et les changements de
//          contact rapprochés fusionnent en une seule. La première lecture
//          réelle a montré que la mise en place d'une sangle consommait dix
//          des seize entrées : un matin raté serait arrivé avec un anneau
//          plein de quelqu'un en train de s'équiper
//   1.15.0 la perte de contact n'arrête plus le minuteur d'une tentative
//          d'armement en cours, seulement celui de la pause. Le même
//          identifiant portait les deux, et 1.12.0 les arrêtait tous deux :
//          mArming restait vrai sans rien pour l'en sortir, et tout contact
//          ultérieur tombait dans la branche qui ne fait rien. Deux heures
//          ainsi, lues directement dans le journal. Cette branche dépose
//          désormais une ligne : son silence avait rendu la lecture indirecte
//   1.16.0 un refus répété ne remplit plus le journal. evaluateRecordingState
//          est rappelé à chaque changement de mouvement autant que de contact,
//          si bien qu'en train la paire « contact vu / refusé pour la même
//          raison » revenait toutes les cinq secondes : trente-deux entrées ne
//          couvraient plus qu'une minute, et la séance réellement démarrée une
//          demi-heure plus tôt était tombée de l'anneau
//   1.17.0 les compteurs qui décident « est-ce un cœur ? » sont remis à zéro
//          au début de chaque tentative. Ils s'appellent ThisTick mais seul le
//          chien de garde les efface, et il ne tourne que pendant un
//          enregistrement : pendant l'armement ils s'accumulaient depuis le
//          démarrage. La porte exigeant plus de plausibles que d'aberrants,
//          une sangle mouillée puis promenée en poche prenait une avance que
//          le vrai pouls ne rattrapait jamais — et seul un enregistrement les
//          efface, qu'il faut armer pour obtenir. Le 6 septembre : sangle
//          mouillée à 11h30, portée à 12h, quatre-vingt-dix minutes de
//          tentatives sur un pouls parfaitement valide. L'état lu par l'app
//          expose désormais ces deux compteurs, la dernière FC vue et l'âge du
//          dernier battement
#define MOVELOAD_APP_VERSION "1.17.0"
