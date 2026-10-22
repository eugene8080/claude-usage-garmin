import Toybox.Application;
import Toybox.Lang;
import Toybox.Test;

//! Unit tests for the parts of the shared watch code that decide what is shown: Snapshot.store()'s
//! group rules (garmin/CONTRACT.md) and the page a complication launch opens on. (:test) code is
//! compiled only into a --unit-test build, never into the .prg that is sideloaded.
//!
//! Run (simulator open):
//!   monkeyc -f garmin/watch-app/monkey.jungle -o <dir>/test.prg -y <key> -d fenix847mm --unit-test
//!   monkeydo <dir>/test.prg fenix847mm /t
(:test)
module UsageTests {

    //! A payload with every group, the way WatchBridge.payloadOf() builds it.
    function fullPayload() as Dictionary {
        return {
            "fh" => 12, "fhr" => 1792310400, "wk" => 40, "wkr" => 1792656000, "ts" => 1792300000,
            "mw" => 3, "mwr" => 1792656000, "mwn" => "Fable",
            "xfh" => -1, "xfhr" => 0, "xwk" => 21, "xwkr" => 1792700000, "xts" => 1792299000,
            "upl" => 55, "uplr" => 1793500000, "uau" => 61, "uaur" => 1793500000,
            "uap" => 100, "uapr" => 1793500000, "uts" => 1792298000,
        };
    }

    function claudeOnly() as Dictionary {
        return { "fh" => 7, "fhr" => 1792310400, "wk" => 8, "wkr" => 1792656000, "ts" => 1792300100 };
    }

    function reset() as Void {
        Storage.clearValues();
    }

    (:test)
    function testFullPayloadStoresEveryGroup(logger as Logger) as Boolean {
        reset();
        Test.assert(Snapshot.store(fullPayload()));
        Test.assertEqual(Snapshot.percent(Snapshot.K_FIVE), 12);
        Test.assertEqual(Snapshot.modelName(), "Fable");
        Test.assert(Snapshot.hasModelWeekly());
        Test.assert(Snapshot.hasNumbers(Snapshot.K_X_FETCHED));
        Test.assertEqual(Snapshot.percent(Snapshot.K_X_WEEK), 21);
        Test.assertEqual(Snapshot.percent(Snapshot.K_U_API), 100);
        Test.assertEqual(Snapshot.resetAt(Snapshot.K_U_PLAN_RESET), 1793500000);
        return true;
    }

    //! A window Orca did not report arrives as -1 inside a complete group: the provider still
    //! has numbers, that one row is just empty.
    (:test)
    function testMissingWindowIsMinusOneNotAbsent(logger as Logger) as Boolean {
        reset();
        Snapshot.store(fullPayload());
        Test.assert(Snapshot.hasNumbers(Snapshot.K_X_FETCHED));
        Test.assertEqual(Snapshot.percent(Snapshot.K_X_FIVE), -1);
        Test.assertEqual(Snapshot.resetAt(Snapshot.K_X_FIVE_RESET), 0);
        return true;
    }

    //! An absent group is cleared: a provider the phone stopped sending is blanked, not kept.
    (:test)
    function testAbsentGroupsAreCleared(logger as Logger) as Boolean {
        reset();
        Snapshot.store(fullPayload());
        Test.assert(Snapshot.store(claudeOnly()));
        Test.assertEqual(Snapshot.percent(Snapshot.K_FIVE), 7);
        Test.assert(!Snapshot.hasModelWeekly());
        Test.assertEqual(Snapshot.percent(Snapshot.K_MODEL), -1);
        Test.assert(!Snapshot.hasNumbers(Snapshot.K_X_FETCHED));
        Test.assert(!Snapshot.hasNumbers(Snapshot.K_U_FETCHED));
        Test.assertEqual(Snapshot.percent(Snapshot.K_U_PLAN), -1);
        return true;
    }

    //! A message with no complete group is rejected and changes nothing - including one whose
    //! only group is missing a key.
    (:test)
    function testIncompleteMessageChangesNothing(logger as Logger) as Boolean {
        reset();
        Snapshot.store(fullPayload());
        Test.assert(!Snapshot.store(null));
        Test.assert(!Snapshot.store({}));
        Test.assert(!Snapshot.store({ "fh" => 1, "fhr" => 0, "wk" => 2, "wkr" => 0 })); // no "ts"
        Test.assertEqual(Snapshot.percent(Snapshot.K_FIVE), 12);
        Test.assert(Snapshot.hasNumbers(Snapshot.K_U_FETCHED));
        return true;
    }

    //! Types are part of a group: a model name that is not a String makes the model group
    //! incomplete, so it is cleared while the rest of the message is stored.
    (:test)
    function testWrongTypeMakesGroupIncomplete(logger as Logger) as Boolean {
        reset();
        var msg = fullPayload();
        msg.put("mwn", 5);
        Test.assert(Snapshot.store(msg));
        Test.assert(!Snapshot.hasModelWeekly());
        Test.assertEqual(Snapshot.percent(Snapshot.K_WEEK), 40);
        msg = fullPayload();
        msg.put("xwk", "21");
        Test.assert(Snapshot.store(msg));
        Test.assert(!Snapshot.hasNumbers(Snapshot.K_X_FETCHED));
        return true;
    }

    //! Hold-to-launch opens the page of the complication it came from (each app's own ids).
    (:test)
    function testStartPageFollowsComplication(logger as Logger) as Boolean {
        var mainPages = [UsageApp.CLAUDE, UsageApp.CODEX, UsageApp.CURSOR];
        var mainMap = [UsageApp.CLAUDE, UsageApp.CLAUDE, UsageApp.CLAUDE, UsageApp.CURSOR];
        Test.assertEqual(UsageApp.startPage(null, mainPages, mainMap), 0);
        Test.assertEqual(UsageApp.startPage({}, mainPages, mainMap), 0);
        Test.assertEqual(UsageApp.startPage({:launchedFromComplication => 3}, mainPages, mainMap), 2);
        Test.assertEqual(UsageApp.startPage({:launchedFromComplication => 1}, mainPages, mainMap), 0);
        Test.assertEqual(UsageApp.startPage({:launchedFromComplication => 9}, mainPages, mainMap), 0);
        var feedPages = [UsageApp.CODEX, UsageApp.CURSOR];
        var feedMap = [UsageApp.CODEX, UsageApp.CODEX, UsageApp.CURSOR, UsageApp.CURSOR];
        Test.assertEqual(UsageApp.startPage({:launchedFromComplication => 1}, feedPages, feedMap), 0);
        Test.assertEqual(UsageApp.startPage({:launchedFromComplication => 2}, feedPages, feedMap), 1);
        return true;
    }
}
