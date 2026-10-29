-- ============================================================
-- IPL Cricket Data Analysis - SQL query library (SQLite 3.25+)
-- Author: Galib Amin
-- Tables: matches, deliveries  |  View: ball_facts
-- ============================================================

-- ---------- Setup: indexes and analysis view ----------
CREATE INDEX IF NOT EXISTS idx_del_match   ON deliveries(match_id);
CREATE INDEX IF NOT EXISTS idx_del_batter  ON deliveries(batter);
CREATE INDEX IF NOT EXISTS idx_del_bowler  ON deliveries(bowler);
CREATE INDEX IF NOT EXISTS idx_m_season    ON matches(season_year);

DROP VIEW IF EXISTS ball_facts;
CREATE VIEW ball_facts AS
SELECT
    d.*,
    m.season_year,
    m.date AS match_date,
    -- legal delivery = not a wide / no-ball
    CASE WHEN d.extras_type IN ('wides', 'noballs') THEN 0 ELSE 1 END AS is_legal,
    -- balls faced by a batter = everything except wides
    CASE WHEN d.extras_type = 'wides' THEN 0 ELSE 1 END AS is_ball_faced,
    -- runs charged to the bowler (byes / leg-byes are not)
    d.batsman_runs
      + CASE WHEN d.extras_type IN ('wides', 'noballs') THEN d.extra_runs ELSE 0 END AS bowler_runs,
    -- wickets credited to the bowler (run-outs etc. are not)
    CASE WHEN d.is_wicket = 1
          AND d.dismissal_kind IN ('caught', 'bowled', 'lbw', 'stumped',
                                   'caught and bowled', 'hit wicket')
         THEN 1 ELSE 0 END AS bowler_wicket,
    -- innings phase (overs are 0-indexed: 0 = first over)
    CASE WHEN d."over" BETWEEN 0 AND 5  THEN 'Powerplay'
         WHEN d."over" BETWEEN 6 AND 14 THEN 'Middle'
         ELSE 'Death' END AS phase
FROM deliveries d
JOIN matches m ON m.id = d.match_id
WHERE d.inning IN (1, 2);          -- exclude super overs

-- ------------------------------------------------------------
-- Q01: Matches, venues and results per season
-- Question  : How has the tournament grown season by season?
-- Techniques: GROUP BY, CASE WHEN
-- ------------------------------------------------------------
SELECT
    season_year,
    COUNT(*)                                                    AS matches,
    COUNT(DISTINCT venue)                                       AS venues,
    SUM(CASE WHEN result = 'no result' THEN 1 ELSE 0 END)       AS no_results,
    SUM(CASE WHEN super_over = 'Y' THEN 1 ELSE 0 END)           AS super_overs
FROM matches
GROUP BY season_year
ORDER BY season_year;

-- ------------------------------------------------------------
-- Q02: Overall team win percentage
-- Question  : Which franchises have the best win record (min. 50 matches)?
-- Techniques: CTE, UNION ALL, CASE WHEN
-- ------------------------------------------------------------
WITH team_matches AS (
    SELECT id, team1 AS team, winner FROM matches
    UNION ALL
    SELECT id, team2 AS team, winner FROM matches
)
SELECT
    team,
    COUNT(*)                                                         AS played,
    SUM(CASE WHEN winner = team THEN 1 ELSE 0 END)                   AS wins,
    ROUND(100.0 * SUM(CASE WHEN winner = team THEN 1 ELSE 0 END)
                / COUNT(*), 2)                                       AS win_pct
FROM team_matches
GROUP BY team
HAVING COUNT(*) >= 50
ORDER BY win_pct DESC;

-- ------------------------------------------------------------
-- Q03: Top 3 teams in every season (by wins)
-- Question  : Who dominated each season?
-- Techniques: CTE, RANK() OVER (PARTITION BY)
-- ------------------------------------------------------------
WITH season_wins AS (
    SELECT season_year, winner AS team, COUNT(*) AS wins
    FROM matches
    WHERE winner IS NOT NULL
    GROUP BY season_year, winner
),
ranked AS (
    SELECT season_year, team, wins,
           RANK() OVER (PARTITION BY season_year ORDER BY wins DESC) AS season_rank
    FROM season_wins
)
SELECT season_year, season_rank, team, wins
FROM ranked
WHERE season_rank <= 3
ORDER BY season_year, season_rank;

-- ------------------------------------------------------------
-- Q04: Champion of every season
-- Question  : Who won the title each year? (winner of the last match of the season = the final)
-- Techniques: CTE, ROW_NUMBER() OVER (PARTITION BY)
-- ------------------------------------------------------------
WITH last_match AS (
    SELECT season_year, winner, venue, date,
           ROW_NUMBER() OVER (PARTITION BY season_year
                              ORDER BY date DESC, id DESC) AS rn
    FROM matches
)
SELECT season_year, winner AS champion, venue, date AS final_date
FROM last_match
WHERE rn = 1
ORDER BY season_year;

-- ------------------------------------------------------------
-- Q05: Number of titles per franchise
-- Question  : Which team has lifted the trophy the most?
-- Techniques: Nested CTEs, window function, aggregation
-- ------------------------------------------------------------
WITH last_match AS (
    SELECT season_year, winner,
           ROW_NUMBER() OVER (PARTITION BY season_year
                              ORDER BY date DESC, id DESC) AS rn
    FROM matches
),
champions AS (
    SELECT season_year, winner FROM last_match WHERE rn = 1 AND winner IS NOT NULL
)
SELECT winner AS team,
       COUNT(*)                          AS titles,
       GROUP_CONCAT(season_year, ', ')   AS seasons
FROM champions
GROUP BY winner
ORDER BY titles DESC, team;

-- ------------------------------------------------------------
-- Q06: Does winning the toss help?
-- Question  : How often does the toss winner also win the match, by toss decision?
-- Techniques: CASE WHEN, conditional aggregation
-- ------------------------------------------------------------
SELECT
    toss_decision,
    COUNT(*)                                                       AS matches,
    SUM(CASE WHEN toss_winner = winner THEN 1 ELSE 0 END)          AS toss_winner_won,
    ROUND(100.0 * SUM(CASE WHEN toss_winner = winner THEN 1 ELSE 0 END)
                / COUNT(*), 2)                                     AS toss_win_match_win_pct
FROM matches
WHERE winner IS NOT NULL
GROUP BY toss_decision;

-- ------------------------------------------------------------
-- Q07: Toss decision trend
-- Question  : Have captains shifted from batting first to fielding first?
-- Techniques: CASE WHEN, percentage by season
-- ------------------------------------------------------------
SELECT
    season_year,
    COUNT(*)                                                           AS matches,
    ROUND(100.0 * SUM(CASE WHEN toss_decision = 'field' THEN 1 ELSE 0 END)
                / COUNT(*), 1)                                         AS pct_chose_field,
    ROUND(100.0 * SUM(CASE WHEN toss_decision = 'bat' THEN 1 ELSE 0 END)
                / COUNT(*), 1)                                         AS pct_chose_bat
FROM matches
GROUP BY season_year
ORDER BY season_year;

-- ------------------------------------------------------------
-- Q08: Chasing vs defending
-- Question  : Is it easier to chase or to defend? (win share by season)
-- Techniques: CASE WHEN, conditional aggregation
-- ------------------------------------------------------------
SELECT
    season_year,
    SUM(CASE WHEN result = 'wickets' THEN 1 ELSE 0 END)  AS chasing_wins,
    SUM(CASE WHEN result = 'runs'    THEN 1 ELSE 0 END)  AS defending_wins,
    ROUND(100.0 * SUM(CASE WHEN result = 'wickets' THEN 1 ELSE 0 END)
                / COUNT(*), 1)                           AS chase_win_pct
FROM matches
WHERE result IN ('runs', 'wickets')
GROUP BY season_year
ORDER BY season_year;

-- ------------------------------------------------------------
-- Q09: Venue scoring profile
-- Question  : Which grounds are the highest scoring? (min. 20 matches)
-- Techniques: CTE, JOIN, conditional AVG
-- ------------------------------------------------------------
WITH inn_totals AS (
    SELECT match_id, inning, SUM(total_runs) AS runs
    FROM deliveries
    WHERE inning IN (1, 2)
    GROUP BY match_id, inning
)
SELECT
    m.venue,
    COUNT(DISTINCT m.id)                                   AS matches,
    ROUND(AVG(CASE WHEN t.inning = 1 THEN t.runs END), 1)  AS avg_1st_innings,
    ROUND(AVG(CASE WHEN t.inning = 2 THEN t.runs END), 1)  AS avg_2nd_innings
FROM matches m
JOIN inn_totals t ON t.match_id = m.id
GROUP BY m.venue
HAVING COUNT(DISTINCT m.id) >= 20
ORDER BY avg_1st_innings DESC
LIMIT 15;

-- ------------------------------------------------------------
-- Q10: Head-to-head records of the biggest rivalries
-- Question  : Who leads the most-played match-ups?
-- Techniques: CTE, CASE WHEN to normalise team pairs
-- ------------------------------------------------------------
WITH pairs AS (
    SELECT
        CASE WHEN team1 < team2 THEN team1 ELSE team2 END AS team_a,
        CASE WHEN team1 < team2 THEN team2 ELSE team1 END AS team_b,
        winner
    FROM matches
)
SELECT
    team_a,
    team_b,
    COUNT(*)                                          AS matches,
    SUM(CASE WHEN winner = team_a THEN 1 ELSE 0 END)  AS team_a_wins,
    SUM(CASE WHEN winner = team_b THEN 1 ELSE 0 END)  AS team_b_wins
FROM pairs
GROUP BY team_a, team_b
ORDER BY matches DESC
LIMIT 15;

-- ------------------------------------------------------------
-- Q11: Longest winning streaks (gaps-and-islands)
-- Question  : What are the longest consecutive-win runs by any team?
-- Techniques: UNION ALL, ROW_NUMBER, gaps-and-islands pattern
-- ------------------------------------------------------------
WITH team_matches AS (
    SELECT id, date, team1 AS team, winner FROM matches
    UNION ALL
    SELECT id, date, team2 AS team, winner FROM matches
),
ordered AS (
    SELECT team, date, id,
           CASE WHEN winner = team THEN 1 ELSE 0 END AS won,
           ROW_NUMBER() OVER (PARTITION BY team ORDER BY date, id) AS rn
    FROM team_matches
),
wins_only AS (
    SELECT team, date,
           rn - ROW_NUMBER() OVER (PARTITION BY team ORDER BY rn) AS grp
    FROM ordered
    WHERE won = 1
)
SELECT team,
       COUNT(*)  AS streak_length,
       MIN(date) AS streak_start,
       MAX(date) AS streak_end
FROM wins_only
GROUP BY team, grp
ORDER BY streak_length DESC
LIMIT 10;

-- ------------------------------------------------------------
-- Q12: Biggest wins by runs
-- Question  : Which were the most one-sided matches when defending?
-- Techniques: CASE WHEN, ORDER BY / LIMIT
-- ------------------------------------------------------------
SELECT
    season_year,
    date,
    winner,
    CASE WHEN winner = team1 THEN team2 ELSE team1 END AS loser,
    result_margin                                     AS won_by_runs,
    venue
FROM matches
WHERE result = 'runs'
ORDER BY result_margin DESC
LIMIT 10;

-- ------------------------------------------------------------
-- Q13: Nail-biters: who wins the close ones?
-- Question  : Which teams win the most matches decided by <=10 runs or <=2 wickets?
-- Techniques: CASE-style filtering, aggregation
-- ------------------------------------------------------------
SELECT
    winner AS team,
    COUNT(*) AS close_wins,
    SUM(CASE WHEN result = 'runs'    THEN 1 ELSE 0 END) AS close_wins_defending,
    SUM(CASE WHEN result = 'wickets' THEN 1 ELSE 0 END) AS close_wins_chasing
FROM matches
WHERE (result = 'runs'    AND result_margin <= 10)
   OR (result = 'wickets' AND result_margin <= 2)
GROUP BY winner
ORDER BY close_wins DESC
LIMIT 10;

-- ------------------------------------------------------------
-- Q14: Player of the Match leaders
-- Question  : Who has won the most Player of the Match awards?
-- Techniques: RANK() OVER, aggregation
-- ------------------------------------------------------------
WITH awards AS (
    SELECT player_of_match AS player, COUNT(*) AS awards
    FROM matches
    WHERE player_of_match IS NOT NULL
    GROUP BY player_of_match
)
SELECT player, awards,
       RANK() OVER (ORDER BY awards DESC) AS award_rank
FROM awards
ORDER BY awards DESC, player
LIMIT 10;

-- ------------------------------------------------------------
-- Q15: All-time top run scorers (with strike rate and average)
-- Question  : Who are the leading run scorers and how efficient are they?
-- Techniques: CTEs, JOIN, view, conditional aggregation
-- ------------------------------------------------------------
WITH bat AS (
    SELECT
        batter,
        COUNT(DISTINCT match_id)                           AS innings,
        SUM(batsman_runs)                                  AS runs,
        SUM(is_ball_faced)                                 AS balls,
        SUM(CASE WHEN batsman_runs = 4 THEN 1 ELSE 0 END)  AS fours,
        SUM(CASE WHEN batsman_runs = 6 THEN 1 ELSE 0 END)  AS sixes
    FROM ball_facts
    GROUP BY batter
),
outs AS (
    SELECT player_dismissed AS batter, COUNT(*) AS dismissals
    FROM ball_facts
    WHERE is_wicket = 1 AND dismissal_kind <> 'retired hurt'
    GROUP BY player_dismissed
)
SELECT
    b.batter, b.innings, b.runs, b.balls,
    ROUND(100.0 * b.runs / b.balls, 2)                 AS strike_rate,
    ROUND(1.0 * b.runs / NULLIF(o.dismissals, 0), 2)   AS average,
    b.fours, b.sixes
FROM bat b
LEFT JOIN outs o ON o.batter = b.batter
ORDER BY b.runs DESC
LIMIT 10;

-- ------------------------------------------------------------
-- Q16: Orange Cap: top run scorer of every season
-- Question  : Who finished as the leading run scorer each year?
-- Techniques: CTE, RANK() OVER (PARTITION BY)
-- ------------------------------------------------------------
WITH season_runs AS (
    SELECT season_year, batter, SUM(batsman_runs) AS runs
    FROM ball_facts
    GROUP BY season_year, batter
),
ranked AS (
    SELECT *, RANK() OVER (PARTITION BY season_year ORDER BY runs DESC) AS rk
    FROM season_runs
)
SELECT season_year, batter AS orange_cap, runs
FROM ranked
WHERE rk = 1
ORDER BY season_year;

-- ------------------------------------------------------------
-- Q17: Career run progression of the top 5 batters
-- Question  : How did the leading batters accumulate their runs season by season?
-- Techniques: CTE, subquery, SUM() OVER (running total)
-- ------------------------------------------------------------
WITH top5 AS (
    SELECT batter
    FROM ball_facts
    GROUP BY batter
    ORDER BY SUM(batsman_runs) DESC
    LIMIT 5
),
season_runs AS (
    SELECT batter, season_year, SUM(batsman_runs) AS runs
    FROM ball_facts
    WHERE batter IN (SELECT batter FROM top5)
    GROUP BY batter, season_year
)
SELECT
    batter,
    season_year,
    runs,
    SUM(runs) OVER (PARTITION BY batter ORDER BY season_year) AS cumulative_runs
FROM season_runs
ORDER BY batter, season_year;

-- ------------------------------------------------------------
-- Q18: Centuries and fifties
-- Question  : Who has the most 100s and 50s in IPL history?
-- Techniques: CTE, CASE WHEN banding
-- ------------------------------------------------------------
WITH innings_scores AS (
    SELECT match_id, batter, SUM(batsman_runs) AS runs
    FROM ball_facts
    GROUP BY match_id, batter
)
SELECT
    batter,
    SUM(CASE WHEN runs >= 100            THEN 1 ELSE 0 END) AS hundreds,
    SUM(CASE WHEN runs BETWEEN 50 AND 99 THEN 1 ELSE 0 END) AS fifties,
    MAX(runs)                                               AS highest_score
FROM innings_scores
GROUP BY batter
HAVING MAX(runs) >= 50
ORDER BY hundreds DESC, fifties DESC
LIMIT 10;

-- ------------------------------------------------------------
-- Q19: Run rate and wickets by innings phase and season
-- Question  : How has scoring changed in the powerplay, middle overs and death overs?
-- Techniques: CASE WHEN (derived phase), conditional aggregation
-- ------------------------------------------------------------
SELECT
    season_year,
    phase,
    SUM(total_runs)                                   AS runs,
    SUM(is_legal)                                     AS legal_balls,
    ROUND(6.0 * SUM(total_runs) / SUM(is_legal), 2)   AS run_rate,
    SUM(is_wicket)                                    AS wickets
FROM ball_facts
GROUP BY season_year, phase
ORDER BY season_year,
         CASE phase WHEN 'Powerplay' THEN 1 WHEN 'Middle' THEN 2 ELSE 3 END;

-- ------------------------------------------------------------
-- Q20: Death-over hitters
-- Question  : Which batters score fastest in overs 16-20? (min. 300 balls)
-- Techniques: Filtered aggregation, HAVING
-- ------------------------------------------------------------
SELECT
    batter,
    SUM(batsman_runs)                                       AS runs,
    SUM(is_ball_faced)                                      AS balls,
    ROUND(100.0 * SUM(batsman_runs) / SUM(is_ball_faced), 2) AS death_strike_rate
FROM ball_facts
WHERE phase = 'Death'
GROUP BY batter
HAVING SUM(is_ball_faced) >= 300
ORDER BY death_strike_rate DESC
LIMIT 10;

-- ------------------------------------------------------------
-- Q21: Top wicket takers (economy, average, strike rate)
-- Question  : Who are the leading bowlers and how economical are they?
-- Techniques: Aggregation over derived columns
-- ------------------------------------------------------------
SELECT
    bowler,
    SUM(bowler_wicket)                                                AS wickets,
    SUM(is_legal)                                                     AS legal_balls,
    ROUND(6.0 * SUM(bowler_runs) / SUM(is_legal), 2)                  AS economy,
    ROUND(1.0 * SUM(bowler_runs) / NULLIF(SUM(bowler_wicket), 0), 2)  AS bowling_average,
    ROUND(1.0 * SUM(is_legal)   / NULLIF(SUM(bowler_wicket), 0), 1)   AS bowling_strike_rate
FROM ball_facts
GROUP BY bowler
ORDER BY wickets DESC
LIMIT 10;

-- ------------------------------------------------------------
-- Q22: Purple Cap: top wicket taker of every season
-- Question  : Who led the wicket charts each year?
-- Techniques: CTE, RANK() OVER (PARTITION BY)
-- ------------------------------------------------------------
WITH season_wkts AS (
    SELECT season_year, bowler, SUM(bowler_wicket) AS wickets
    FROM ball_facts
    GROUP BY season_year, bowler
),
ranked AS (
    SELECT *, RANK() OVER (PARTITION BY season_year ORDER BY wickets DESC) AS rk
    FROM season_wkts
)
SELECT season_year, bowler AS purple_cap, wickets
FROM ranked
WHERE rk = 1
ORDER BY season_year;

-- ------------------------------------------------------------
-- Q23: Death-over bowling specialists
-- Question  : Who bowls the most economical death overs? (min. 300 balls)
-- Techniques: Filtered aggregation, HAVING
-- ------------------------------------------------------------
SELECT
    bowler,
    SUM(is_legal)                                         AS legal_balls,
    SUM(bowler_wicket)                                    AS wickets,
    ROUND(6.0 * SUM(bowler_runs) / SUM(is_legal), 2)      AS death_economy
FROM ball_facts
WHERE phase = 'Death'
GROUP BY bowler
HAVING SUM(is_legal) >= 300
ORDER BY death_economy ASC
LIMIT 10;

-- ------------------------------------------------------------
-- Q24: How do batters get out?
-- Question  : What share of dismissals does each mode account for?
-- Techniques: Window function over the whole result set: SUM(COUNT(*)) OVER ()
-- ------------------------------------------------------------
SELECT
    dismissal_kind,
    COUNT(*)                                            AS dismissals,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS pct_of_total
FROM ball_facts
WHERE is_wicket = 1 AND dismissal_kind IS NOT NULL
GROUP BY dismissal_kind
ORDER BY dismissals DESC;

-- ------------------------------------------------------------
-- Q25: Highest team totals
-- Question  : What are the biggest innings totals ever posted?
-- Techniques: CTE, JOIN
-- ------------------------------------------------------------
WITH totals AS (
    SELECT match_id, inning, batting_team, bowling_team,
           SUM(total_runs) AS runs,
           SUM(is_wicket)  AS wickets_lost
    FROM deliveries
    WHERE inning IN (1, 2)
    GROUP BY match_id, inning, batting_team, bowling_team
)
SELECT t.batting_team, t.bowling_team AS against, t.runs, t.wickets_lost,
       m.season_year, m.venue
FROM totals t
JOIN matches m ON m.id = t.match_id
ORDER BY t.runs DESC
LIMIT 10;

-- ------------------------------------------------------------
-- Q26: Powerplay score vs. winning chances
-- Question  : Does a big powerplay translate into wins?
-- Techniques: CTEs, CASE WHEN banding, AVG of a flag
-- ------------------------------------------------------------
WITH pp AS (
    SELECT match_id, batting_team AS team, SUM(total_runs) AS pp_runs
    FROM deliveries
    WHERE inning IN (1, 2) AND "over" <= 5
    GROUP BY match_id, batting_team
),
flagged AS (
    SELECT pp.pp_runs,
           CASE WHEN m.winner = pp.team THEN 1 ELSE 0 END AS won,
           CASE WHEN pp.pp_runs >= 60 THEN '4) 60+'
                WHEN pp.pp_runs >= 50 THEN '3) 50-59'
                WHEN pp.pp_runs >= 40 THEN '2) 40-49'
                ELSE '1) under 40' END                    AS pp_band
    FROM pp
    JOIN matches m ON m.id = pp.match_id
    WHERE m.winner IS NOT NULL
)
SELECT pp_band,
       COUNT(*)                     AS innings,
       ROUND(100.0 * AVG(won), 1)   AS win_pct
FROM flagged
GROUP BY pp_band
ORDER BY pp_band;

-- ------------------------------------------------------------
-- Q27: Bounce-back ability
-- Question  : Which teams recover best after a defeat? (win % after a loss vs after a win)
-- Techniques: CTEs, LAG() OVER (PARTITION BY ... ORDER BY ...)
-- ------------------------------------------------------------
WITH team_matches AS (
    SELECT id, date, team1 AS team, winner FROM matches
    UNION ALL
    SELECT id, date, team2 AS team, winner FROM matches
),
seq AS (
    SELECT team,
           CASE WHEN winner = team THEN 1 ELSE 0 END AS won,
           LAG(CASE WHEN winner = team THEN 1 ELSE 0 END)
               OVER (PARTITION BY team ORDER BY date, id) AS prev_won
    FROM team_matches
)
SELECT
    team,
    COUNT(*) AS matches,
    ROUND(100.0 * AVG(CASE WHEN prev_won = 0 THEN won END), 1) AS win_pct_after_loss,
    ROUND(100.0 * AVG(CASE WHEN prev_won = 1 THEN won END), 1) AS win_pct_after_win
FROM seq
WHERE prev_won IS NOT NULL
GROUP BY team
HAVING COUNT(*) >= 50
ORDER BY win_pct_after_loss DESC;

-- ------------------------------------------------------------
-- Q28: Rolling 5-match form (peak form per team)
-- Question  : What was each team's best 5-match run of form?
-- Techniques: SUM() OVER with ROWS BETWEEN frame, CTE
-- ------------------------------------------------------------
WITH team_matches AS (
    SELECT id, date, team1 AS team, winner FROM matches
    UNION ALL
    SELECT id, date, team2 AS team, winner FROM matches
),
form AS (
    SELECT team, date,
           SUM(CASE WHEN winner = team THEN 1 ELSE 0 END)
               OVER (PARTITION BY team ORDER BY date, id
                     ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) AS wins_last_5,
           ROW_NUMBER() OVER (PARTITION BY team ORDER BY date, id) AS match_no
    FROM team_matches
)
SELECT team,
       MAX(wins_last_5) AS best_5_match_wins,
       COUNT(CASE WHEN wins_last_5 = 5 THEN 1 END) AS five_from_five_windows
FROM form
WHERE match_no >= 5
GROUP BY team
HAVING COUNT(*) >= 30
ORDER BY five_from_five_windows DESC, team;

