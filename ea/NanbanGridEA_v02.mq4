//+------------------------------------------------------------------+
//| NanbanGridEA_v02.mq4  v0.2.2（v0.2ファイルへの上書き版）          |
//| 楽天MT4向け ロング専用グリッドEA（研究・検証用）                 |
//| v0.2.2: 信号でパラメータ（慎重側のみ）も受け取れるようにした版。  |
//| v0.2.1: 発注方式を「水準クロス方式」に修正した版。                |
//| v0.2.1の変更点:                                                  |
//|  - グリッド発注は、価格が水準そのものを下抜けたときだけ行う      |
//|    （v0.2までは「水準のゾーンに入っただけ」で次の水準まで買って   |
//|    しまい、実効間隔が設計より圧縮される問題があった）            |
//|  - 信号JSONの読み取りを UTF-8 明示にし、reason の文字化けを解消  |
//|                                                                  |
//| 設計の正本: ~/workspace/investment-automation/ea-design-v1.md    |
//|             ~/workspace/investment-automation/signal-design-v1.md|
//|                                                                  |
//| 信号連携の要点:                                                  |
//|  - マルが発行するモード信号(JSON)を WebRequest で定期取得する    |
//|  - 信号は「弱める・止める」方向にだけ作用する（非対称原則）      |
//|  - 取得失敗・期限切れ・形式異常は無効として慎重側に倒れる        |
//|    (fail-closed)。無効が続くと EXIT_ONLY 相当に格上げする        |
//|  - CLOSE_ALL は CloseAllConfirmPolls 回連続で確認してから実行    |
//|  - MT4の「ツール→オプション→エキスパートアドバイザー」で        |
//|    SignalURL のドメインを WebRequest 許可リストに登録が必要      |
//|  - WebRequest はストラテジーテスターでは動作しない               |
//+------------------------------------------------------------------+
#property copyright   ""
#property version     "0.22"
#property strict
#property description "Long-only grid EA with Maru signal link (research use)."

//------------------------- 入力パラメータ ---------------------------
input double GridStepYen       = 0.05;        // グリッド間隔（円）
input double TakeProfitRatio   = 0.5;         // 利確幅 = 間隔 × この倍率
input double Lots              = 0.01;        // 1建玉のロット（0.01 = 1,000通貨）
input int    MaxPositions      = 5;           // 同時保有の上限（本）
input bool   UseTrendFilter    = true;        // トレンドフィルターを使う
input ENUM_TIMEFRAMES TrendTimeframe = PERIOD_H4; // トレンド判定の時間足
input int    TrendMAPeriod     = 200;         // トレンド判定MA期間（SMA・終値）
input double RiskCapital       = 10000.0;     // 停止判定の基準額（円）※口座残高ではない
input double DailyLossPct      = 3.0;         // 日次損失の上限（RiskCapital比 %）
input double PauseDDPct        = 15.0;        // 新規停止するDD（ピーク比 %）
input double FullStopDDPct     = 30.0;        // 全決済＋無効化するDD（ピーク比 %）
input double MaxSpreadPips     = 1.4;         // 新規を許可する最大スプレッド（pips）
input int    MagicNumber       = 20261116;    // マジックナンバー（v0.1と同一＝建玉を引き継ぐ）
input int    ServerGMTOffsetHours = 2;        // サーバー時刻のGMTオフセット（楽天MT4: 冬2 / 夏3）
input bool   StopNewOnWeekend  = true;        // 週末前の新規停止（金曜夜JST〜）
input int    WeekendBlockHourJST = 22;        // 週末ブロック開始時刻（金曜・JST時）
input bool   UseMaintenanceBlock = true;      // 日次メンテナンス帯（JST 06:50-07:15）の新規停止
input int    SlippagePips      = 3;           // 許容スリッページ（pips）
input bool   ManualResetState  = false;       // trueで起動時に状態（ピーク/無効化）を初期化
input bool   EnableLog         = true;        // CSVログを出す
//--- 信号連携（v0.2で追加） ---
input bool   UseSignal         = true;        // 信号連携を使う
input string SignalURL         = "";          // 信号JSONのURL（空なら連携オフとして v0.1 動作）
input int    SignalPollMinutes = 15;          // 信号の取得間隔（分）
input int    SignalFailHoursToExit = 24;      // 信号無効がこの時間続いたら EXIT_ONLY 相当に格上げ
input int    CloseAllConfirmPolls  = 2;       // CLOSE_ALL をこの回数連続確認してから実行
input bool   UseSignalParams     = true;      // 信号JSONのパラメータ指定を受け付ける（慎重側のみ・Lots/RiskCapitalは不可）

//------------------------- グローバル状態 ---------------------------
string   g_symbol;                 // 対象シンボル（チャートのシンボル）
string   g_stateFile;              // 状態ファイル名（共通フォルダ）
string   g_logFile;                // ログファイル名（共通フォルダ）
double   g_startAcctEquity = 0.0;  // EA初回起動時の口座評価額（円）
double   g_peakVE          = 0.0;  // 仮想評価額のピーク（RiskCapital起点）
bool     g_disabled        = false;// 全停止後の無効化フラグ（永続化）
string   g_dayKey          = "";   // 現在のJST日付キー "YYYY-MM-DD"
double   g_dayStartVE      = 0.0;  // JST日初の仮想評価額スナップショット
double   g_anchorLevel     = 0.0;  // 起動時の基準水準（情報用）
double   g_prevBid         = 0.0;  // 前ティックのBid（水準クロス判定用）
datetime g_lastStateSave   = 0;    // 状態ファイルの最終保存時刻
// フィルター発動ログの重複防止（状態が変わったときだけログする）
bool g_wasDdPaused=false, g_wasDailyBlocked=false, g_wasTrendBlocked=false,
     g_wasSpreadBlocked=false, g_wasTimeBlocked=false, g_wasMaxPosLogged=false,
     g_wasSigBlocked=false;
//--- 信号連携の状態 ---
string   g_sigMode         = "NONE"; // NORMAL/CAUTION/EXIT_ONLY/CLOSE_ALL/INVALID/NONE
datetime g_lastPoll        = 0;    // 最終ポーリング時刻（サーバー時刻）
datetime g_lastValidFetch  = 0;    // 最後に有効な信号を取れた時刻（サーバー時刻）
datetime g_sigIssuedAt     = 0;    // 適用中信号の issued_at（サーバー時刻換算）
datetime g_initTime        = 0;    // 起動時刻（無効継続時間の起点フォールバック）
int      g_closeAllCount   = 0;    // CLOSE_ALL の連続確認回数
bool     g_sigHalt         = false;// CLOSE_ALL 実行後の停止（NORMAL信号まで継続・永続化）

//--- 信号パラメータの実効値（初期値＝入力パラメータ。信号で慎重側にだけ上書きされる） ---
double g_effGridStep;  int g_effMaxPos;  double g_effTpRatio;  double g_effMaxSpread;
bool   g_effTrendFilter;  double g_effDailyLossPct;  double g_effPauseDDPct;  double g_effFullStopDDPct;
string g_lastParamReject = "";       // 同じ却下ログの連続出力を防ぐ
bool     g_exitApplied     = false;// EXIT_ONLY 入り時の利確詰めを適用済みか

//+------------------------------------------------------------------+
//| ユーティリティ                                                   |
//+------------------------------------------------------------------+
double PipSize()
{
   // JPYペア（3桁）・5桁ブローカーでは 1pip = 10ポイント、それ以外は 1ポイント
   if(Digits == 3 || Digits == 5) return Point * 10.0;
   return Point;
}

int SlippagePoints()
{
   double ratio = PipSize() / Point;           // 1 or 10
   return (int)MathRound(SlippagePips * ratio);
}

double SpreadPips()
{
   if(PipSize() <= 0.0) return 0.0;
   return (Ask - Bid) / PipSize();
}

// サーバー時刻 -> JST（オフセットはパラメータで与える簡易換算）
datetime JstNow()
{
   return TimeCurrent() + (9 - ServerGMTOffsetHours) * 3600;
}

string JstDayKey()
{
   MqlDateTime st;
   TimeToStruct(JstNow(), st);
   return StringFormat("%04d-%02d-%02d", st.year, st.mon, st.day);
}

// 価格以下の最大のグリッド水準（水準は間隔の絶対倍数。シミュレーターと同一）
double LevelAtOrBelow(double price)
{
   double k = MathFloor(price / g_effGridStep + 1e-6);
   return NormalizeDouble(k * g_effGridStep, 8);
}

// 仮想評価額: RiskCapital を起点に、口座評価額の増減をそのまま写す。
// デモ口座（残高500万円）でも少額口座と同じ％判定になるための仕掛け。
double VirtualEquity()
{
   return RiskCapital + (AccountEquity() - g_startAcctEquity);
}

//+------------------------------------------------------------------+
//| ログ（CSV・共通フォルダへ追記）                                  |
//+------------------------------------------------------------------+
void LogEvent(string type, double price, double lots, string detail)
{
   string line = StringFormat("%s,%s,%s,%s,%.5f,%.2f,%s",
                              TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                              type, g_symbol, IntegerToString(MagicNumber),
                              price, lots, detail);
   StringReplace(line, "\r", " ");
   StringReplace(line, "\n", " ");
   Print(line);
   if(!EnableLog) return;

   bool needHeader = !FileIsExist(g_logFile, FILE_COMMON);
   int h = FileOpen(g_logFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   if(needHeader)
      FileWriteString(h, "server_time,type,symbol,magic,price,lots,detail\r\n");
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, line + "\r\n");
   FileClose(h);
}

//+------------------------------------------------------------------+
//| 状態の永続化（ピーク・無効化フラグ・日次スナップショット）       |
//| 土曜ログアウトや再起動で消えないよう共通フォルダのファイルに保存 |
//+------------------------------------------------------------------+
void SaveState()
{
   int h = FileOpen(g_stateFile, FILE_WRITE | FILE_TXT | FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, StringFormat("start_equity=%.2f\n", g_startAcctEquity));
   FileWriteString(h, StringFormat("peak_ve=%.2f\n",      g_peakVE));
   FileWriteString(h, StringFormat("disabled=%d\n",       g_disabled ? 1 : 0));
   FileWriteString(h, StringFormat("day_key=%s\n",        g_dayKey));
   FileWriteString(h, StringFormat("day_start_ve=%.2f\n", g_dayStartVE));
   FileWriteString(h, StringFormat("anchor=%.8f\n",       g_anchorLevel));
   FileWriteString(h, StringFormat("sig_halt=%d\n",       g_sigHalt ? 1 : 0));
   FileClose(h);
   g_lastStateSave = TimeCurrent();
}

bool LoadState()
{
   if(!FileIsExist(g_stateFile, FILE_COMMON)) return false;
   int h = FileOpen(g_stateFile, FILE_READ | FILE_TXT | FILE_COMMON);
   if(h == INVALID_HANDLE) return false;
   while(!FileIsEnding(h))
   {
      string line = FileReadString(h);
      int pos = StringFind(line, "=");
      if(pos < 0) continue;
      string key = StringSubstr(line, 0, pos);
      string val = StringSubstr(line, pos + 1);
      if(key == "start_equity") g_startAcctEquity = StringToDouble(val);
      else if(key == "peak_ve") g_peakVE          = StringToDouble(val);
      else if(key == "disabled") g_disabled       = (StringToInteger(val) != 0);
      else if(key == "day_key") g_dayKey          = val;
      else if(key == "day_start_ve") g_dayStartVE = StringToDouble(val);
      else if(key == "anchor") g_anchorLevel      = StringToDouble(val);
      else if(key == "sig_halt") g_sigHalt        = (StringToInteger(val) != 0);
   }
   FileClose(h);
   return (g_startAcctEquity > 0.0);
}

//+------------------------------------------------------------------+
//| 自分の建玉の管理                                                 |
//+------------------------------------------------------------------+
bool IsOwnOrder()
{
   return OrderSymbol() == g_symbol
       && OrderMagicNumber() == MagicNumber
       && OrderType() == OP_BUY;
}

int CountOwnPositions()
{
   int n = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(IsOwnOrder()) n++;
   }
   return n;
}

// 注文コメント "NG:<水準>" から水準を取り出す。取れなければ建値から推定。
double LevelOfOrder()
{
   string c = OrderComment();
   if(StringFind(c, "NG:") == 0)
      return StringToDouble(StringSubstr(c, 3));
   return NormalizeDouble(MathRound(OrderOpenPrice() / g_effGridStep) * g_effGridStep, 8);
}

bool LevelOccupied(double level)
{
   for(int i = 0; i < OrdersTotal(); i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!IsOwnOrder()) continue;
      if(MathAbs(LevelOfOrder() - level) < g_effGridStep * 0.25) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| 発注（リトライ最大3回・戻り値とエラーを必ず確認/記録）           |
//| SLは付けない: 損失の停止はリスクエンジン（DD判定）が担う設計。   |
//| 理由は README.md「SLを注文に付けない理由」参照。                 |
//+------------------------------------------------------------------+
bool OpenBuy(double level)
{
   double tpWidth = g_effGridStep * g_effTpRatio;
   for(int attempt = 1; attempt <= 3; attempt++)
   {
      RefreshRates();
      double ask = NormalizeDouble(Ask, Digits);
      double tp  = NormalizeDouble(ask + tpWidth, Digits);
      double minDist = MarketInfo(g_symbol, MODE_STOPLEVEL) * Point;
      if(tp - ask < minDist + Point)
      {
         LogEvent("SKIP_STOPLEVEL", ask, Lots,
                  StringFormat("level=%.5f min_dist=%.5f", level, minDist));
         return false;
      }
      string comment = StringFormat("NG:%.5f", level);
      int ticket = OrderSend(g_symbol, OP_BUY, Lots, ask, SlippagePoints(),
                             0.0, tp, comment, MagicNumber, 0, clrDodgerBlue);
      if(ticket > 0)
      {
         LogEvent("OPEN", ask, Lots,
                  StringFormat("level=%.5f tp=%.5f ticket=%d attempt=%d",
                               level, tp, ticket, attempt));
         return true;
      }
      int err = GetLastError();
      LogEvent("OPEN_ERROR", ask, Lots,
               StringFormat("level=%.5f error=%d attempt=%d", level, err, attempt));
      Sleep(500);
   }
   return false;
}

bool CloseOwnPosition(int ticket, string reason)
{
   for(int attempt = 1; attempt <= 3; attempt++)
   {
      if(!OrderSelect(ticket, SELECT_BY_TICKET)) return true; // 既に無い
      RefreshRates();
      double bid = NormalizeDouble(Bid, Digits);
      if(OrderClose(ticket, OrderLots(), bid, SlippagePoints(), clrTomato))
      {
         LogEvent("CLOSE", bid, OrderLots(),
                  StringFormat("ticket=%d reason=%s", ticket, reason));
         return true;
      }
      int err = GetLastError();
      LogEvent("CLOSE_ERROR", bid, OrderLots(),
               StringFormat("ticket=%d error=%d attempt=%d reason=%s",
                            ticket, err, attempt, reason));
      Sleep(500);
   }
   return false;
}

void CloseAllOwn(string reason)
{
   // 後ろから処理する（決済でインデックスがずれるため）
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!IsOwnOrder()) continue;
      CloseOwnPosition(OrderTicket(), reason);
   }
}

//+------------------------------------------------------------------+
//| フィルター群                                                     |
//+------------------------------------------------------------------+
bool TrendAllows()
{
   if(!g_effTrendFilter) return true;
   double ma = iMA(g_symbol, TrendTimeframe, TrendMAPeriod, 0,
                   MODE_SMA, PRICE_CLOSE, 0);
   if(ma <= 0.0) return false;   // データ不足時は安全側（新規しない）
   return Bid >= ma;
}

bool TimeBlocks()
{
   MqlDateTime st;
   TimeToStruct(JstNow(), st);
   // 日次メンテナンス帯（楽天MT4は 06:55-07:10 JST）の前後を避ける
   if(UseMaintenanceBlock)
   {
      int mins = st.hour * 60 + st.min;
      if(mins >= 6 * 60 + 50 && mins < 7 * 60 + 15) return true;
   }
   // 週末前ブロック: 金曜の指定時刻以降と土曜は新規しない
   // （取引時間自体は土曜06:55 JSTまで。週末ギャップを新規で持ち越さない）
   if(StopNewOnWeekend)
   {
      if(st.day_of_week == 6) return true;                       // 土曜
      if(st.day_of_week == 5 && st.hour >= WeekendBlockHourJST)  // 金曜夜
         return true;
   }
   return false;
}

// 状態変化時だけフィルター発動/解除をログする
void LogFilterChange(string name, bool nowBlocked, bool &wasBlocked,
                     double price, string detail)
{
   if(nowBlocked && !wasBlocked)
      LogEvent("FILTER_ON", price, 0.0, name + " " + detail);
   else if(!nowBlocked && wasBlocked)
      LogEvent("FILTER_OFF", price, 0.0, name + " " + detail);
   wasBlocked = nowBlocked;
}

//+------------------------------------------------------------------+
//| 信号連携（v0.2）                                                 |
//| 設計: signal-design-v1.md §3〜§6                                 |
//+------------------------------------------------------------------+
// JSON本文から "key": "value" の文字列値を取り出す（最小実装）
string ExtractJsonString(string body, string key)
{
   string pat = "\"" + key + "\"";
   int p = StringFind(body, pat);
   if(p < 0) return "";
   int colon = StringFind(body, ":", p + StringLen(pat));
   if(colon < 0) return "";
   int q1 = StringFind(body, "\"", colon);
   if(q1 < 0) return "";
   int q2 = StringFind(body, "\"", q1 + 1);
   if(q2 < 0) return "";
   return StringSubstr(body, q1 + 1, q2 - q1 - 1);
}

// 数値フィールドの簡易抽出（信号は自前発行の固定形式が前提）
bool ExtractJsonNumber(string body, string key, double &value)
{
   string pat = "\"" + key + "\"";
   int p = StringFind(body, pat);
   if(p < 0) return false;
   int colon = StringFind(body, ":", p + StringLen(pat));
   if(colon < 0) return false;
   int i = colon + 1;
   while(i < StringLen(body) && (StringGetChar(body, i) == ' ' || StringGetChar(body, i) == '\t')) i++;
   int j = i;
   while(j < StringLen(body))
   {
      ushort c = StringGetChar(body, j);
      if((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+') j++;
      else break;
   }
   if(j <= i) return false;
   value = StringToDouble(StringSubstr(body, i, j - i));
   return true;
}

// 真偽フィールドの簡易抽出
bool ExtractJsonBool(string body, string key, bool &value)
{
   string pat = "\"" + key + "\"";
   int p = StringFind(body, pat);
   if(p < 0) return false;
   int colon = StringFind(body, ":", p + StringLen(pat));
   if(colon < 0) return false;
   int i = colon + 1;
   while(i < StringLen(body) && (StringGetChar(body, i) == ' ' || StringGetChar(body, i) == '\t')) i++;
   if(StringSubstr(body, i, 4) == "true")  { value = true;  return true; }
   if(StringSubstr(body, i, 5) == "false") { value = false; return true; }
   return false;
}

// 実効パラメータを入力値（人間が設定した基準）へ戻す
void ResetEffectiveParams()
{
   g_effGridStep = GridStepYen;  g_effTpRatio = TakeProfitRatio;  g_effMaxPos = MaxPositions;
   g_effMaxSpread = MaxSpreadPips;  g_effTrendFilter = UseTrendFilter;
   g_effDailyLossPct = DailyLossPct;  g_effPauseDDPct = PauseDDPct;  g_effFullStopDDPct = FullStopDDPct;
}

void ParamReject(string key, string detail)
{
   string msg = "key=" + key + " " + detail;
   if(msg != g_lastParamReject)
   {
      LogEvent("SIGNAL_PARAM_REJECT", Bid, 0.0, msg);
      g_lastParamReject = msg;
   }
}

// 信号JSONの params を実効値へ反映する。
// 非対称原則: 信号は「慎重側」へしか動かせない。各パラメータは入力値（基準）との
// 方向チェックと絶対範囲チェックの両方を通ったものだけ採用し、他は無視する。
// Lots と RiskCapital は信号では一切変更できない。
void ApplySignalParams(string body)
{
   if(!UseSignalParams) return;
   double v; bool b; bool changed = false;
   if(ExtractJsonNumber(body, "grid_step", v))
   {
      if(v >= GridStepYen && v <= 0.20)
      { if(MathAbs(v - g_effGridStep) > 1e-9) { g_effGridStep = v; changed = true; } }
      else ParamReject("grid_step", "value=" + DoubleToString(v, 3) + " (widen-only vs input, max 0.20)");
   }
   if(ExtractJsonNumber(body, "tp_ratio", v))
   {
      if(v >= 0.25 && v <= TakeProfitRatio)
      { if(MathAbs(v - g_effTpRatio) > 1e-9) { g_effTpRatio = v; changed = true; } }
      else ParamReject("tp_ratio", "value=" + DoubleToString(v, 2) + " (shrink-only vs input, min 0.25)");
   }
   if(ExtractJsonNumber(body, "max_positions", v))
   {
      int iv = (int)MathRound(v);
      if(iv >= 1 && iv <= MaxPositions)
      { if(iv != g_effMaxPos) { g_effMaxPos = iv; changed = true; } }
      else ParamReject("max_positions", "value=" + IntegerToString(iv) + " (decrease-only vs input, min 1)");
   }
   if(ExtractJsonNumber(body, "max_spread_pips", v))
   {
      if(v >= 0.7 && v <= MaxSpreadPips)
      { if(MathAbs(v - g_effMaxSpread) > 1e-9) { g_effMaxSpread = v; changed = true; } }
      else ParamReject("max_spread_pips", "value=" + DoubleToString(v, 1) + " (tighten-only vs input, min 0.7)");
   }
   if(ExtractJsonBool(body, "trend_filter", b))
   {
      if(b) { if(!g_effTrendFilter) { g_effTrendFilter = true; changed = true; } }
      else ParamReject("trend_filter", "value=false (signal cannot turn the filter OFF)");
   }
   if(ExtractJsonNumber(body, "daily_loss_pct", v))
   {
      if(v >= 1.0 && v <= DailyLossPct)
      { if(MathAbs(v - g_effDailyLossPct) > 1e-9) { g_effDailyLossPct = v; changed = true; } }
      else ParamReject("daily_loss_pct", "value=" + DoubleToString(v, 1) + " (stricter-only vs input, min 1.0)");
   }
   if(ExtractJsonNumber(body, "pause_dd_pct", v))
   {
      if(v >= 5.0 && v <= PauseDDPct)
      { if(MathAbs(v - g_effPauseDDPct) > 1e-9) { g_effPauseDDPct = v; changed = true; } }
      else ParamReject("pause_dd_pct", "value=" + DoubleToString(v, 1) + " (stricter-only vs input, min 5.0)");
   }
   if(ExtractJsonNumber(body, "full_stop_dd_pct", v))
   {
      if(v >= 10.0 && v <= FullStopDDPct && v > g_effPauseDDPct)
      { if(MathAbs(v - g_effFullStopDDPct) > 1e-9) { g_effFullStopDDPct = v; changed = true; } }
      else ParamReject("full_stop_dd_pct", "value=" + DoubleToString(v, 1) + " (stricter-only vs input, min 10.0, must exceed pause)");
   }
   if(changed)
      LogEvent("SIGNAL_PARAMS", Bid, 0.0,
               "grid=" + DoubleToString(g_effGridStep, 3) +
               " tp=" + DoubleToString(g_effTpRatio, 2) +
               " maxpos=" + IntegerToString(g_effMaxPos) +
               " spread=" + DoubleToString(g_effMaxSpread, 1) +
               " trend=" + (g_effTrendFilter ? "1" : "0") +
               " daily=" + DoubleToString(g_effDailyLossPct, 1) +
               " pause=" + DoubleToString(g_effPauseDDPct, 1) +
               " full=" + DoubleToString(g_effFullStopDDPct, 1));
}

// "2026-11-18T07:00:00+09:00"（JST表記）をサーバー時刻へ換算する
datetime JstIsoToServer(string iso)
{
   if(StringLen(iso) < 19) return 0;
   MqlDateTime st;
   st.year = (int)StringToInteger(StringSubstr(iso, 0, 4));
   st.mon  = (int)StringToInteger(StringSubstr(iso, 5, 2));
   st.day  = (int)StringToInteger(StringSubstr(iso, 8, 2));
   st.hour = (int)StringToInteger(StringSubstr(iso, 11, 2));
   st.min  = (int)StringToInteger(StringSubstr(iso, 14, 2));
   st.sec  = (int)StringToInteger(StringSubstr(iso, 17, 2));
   datetime jst = StructToTime(st);
   if(jst <= 0) return 0;
   return jst - (9 - ServerGMTOffsetHours) * 3600;
}

void MarkSignalInvalid(string why)
{
   g_closeAllCount = 0;
   if(g_sigMode != "INVALID")
   {
      LogEvent("SIGNAL_INVALID", Bid, 0.0, "reason=" + why);
      g_sigMode = "INVALID";
      ResetEffectiveParams();   // 信号が死んだらパラメータは基準（入力値）へ戻す
      g_exitApplied = false;
   }
}

// 信号を1回取得して検証・反映する（fail-closed: 失敗はすべて INVALID）
void FetchSignal()
{
   g_lastPoll = TimeCurrent();
   uchar data[];
   uchar result[];
   string reqHeaders = NULL;
   string resHeaders = "";
   ResetLastError();
   int res = WebRequest("GET", SignalURL, reqHeaders, 5000, data, result, resHeaders);
   if(res != 200)
   {
      LogEvent("SIGNAL_FETCH_ERROR", Bid, 0.0,
               StringFormat("http=%d err=%d", res, GetLastError()));
      MarkSignalInvalid("fetch");
      return;
   }
   string body = CharArrayToString(result, 0, -1, CP_UTF8);
   string mode   = ExtractJsonString(body, "mode");
   string issued = ExtractJsonString(body, "issued_at");
   string valid  = ExtractJsonString(body, "valid_until");
   string reason = ExtractJsonString(body, "reason");
   if(mode == "" || issued == "" || valid == "")
   {
      MarkSignalInvalid("parse");
      return;
   }
   if(mode != "NORMAL" && mode != "CAUTION" &&
      mode != "EXIT_ONLY" && mode != "CLOSE_ALL")
   {
      MarkSignalInvalid("unknown_mode");
      return;
   }
   datetime issuedSrv = JstIsoToServer(issued);
   datetime validSrv  = JstIsoToServer(valid);
   if(issuedSrv <= 0 || validSrv <= 0)
   {
      MarkSignalInvalid("time_parse");
      return;
   }
   if(TimeCurrent() > validSrv)
   {
      MarkSignalInvalid("expired");
      return;
   }
   if(g_sigIssuedAt > 0 && issuedSrv < g_sigIssuedAt)
   {
      MarkSignalInvalid("rollback");
      return;
   }
   // 有効な信号として適用
   g_sigIssuedAt    = issuedSrv;
   g_lastValidFetch = TimeCurrent();
   ApplySignalParams(body);
   if(mode == "CLOSE_ALL") g_closeAllCount++;
   else                    g_closeAllCount = 0;
   if(mode != g_sigMode)
   {
      LogEvent("SIGNAL_MODE", Bid, 0.0,
               StringFormat("mode=%s reason=%s", mode, reason));
      g_sigMode     = mode;
      g_exitApplied = false;
   }
   if(mode == "NORMAL" && g_sigHalt)
   {
      g_sigHalt = false;
      SaveState();
      LogEvent("SIGNAL_HALT_OFF", Bid, 0.0, "normal signal received");
   }
}

// 信号が無効な状態が続いている時間（時間）
double SignalInvalidHours()
{
   datetime base = (g_lastValidFetch > 0) ? g_lastValidFetch : g_initTime;
   if(base <= 0) return 0.0;
   return (TimeCurrent() - base) / 3600.0;
}

// EXIT_ONLY 入り時: 既存建玉の利確を半分に詰める（戻りで軽くする）
void TightenTakeProfits()
{
   double tpWidth = g_effGridStep * g_effTpRatio * 0.5;
   double minDist = MarketInfo(g_symbol, MODE_STOPLEVEL) * Point;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!IsOwnOrder()) continue;
      double newTp = NormalizeDouble(OrderOpenPrice() + tpWidth, Digits);
      if(newTp >= OrderTakeProfit() - Point) continue;  // 既に十分近い
      RefreshRates();
      if(newTp < Bid + minDist + Point) continue;       // 近すぎる場合は触らない
      if(OrderModify(OrderTicket(), OrderOpenPrice(), 0.0, newTp, 0, clrGold))
         LogEvent("TP_TIGHTEN", Bid, OrderLots(),
                  StringFormat("ticket=%d new_tp=%.5f", OrderTicket(), newTp));
      else
         LogEvent("TP_TIGHTEN_ERROR", Bid, OrderLots(),
                  StringFormat("ticket=%d err=%d", OrderTicket(), GetLastError()));
   }
}

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   g_symbol    = Symbol();
   g_stateFile = StringFormat("NanbanGridEA_%s_%d_state.txt", g_symbol, MagicNumber);
   g_logFile   = StringFormat("NanbanGridEA_%s_%d_log.csv",   g_symbol, MagicNumber);
   g_initTime  = TimeCurrent();

   if(GridStepYen <= 0.0 || TakeProfitRatio <= 0.0 || RiskCapital <= 0.0 ||
      Lots <= 0.0 || MaxPositions <= 0 ||
      SignalPollMinutes <= 0 || CloseAllConfirmPolls <= 0)
   {
      Print("NanbanGridEA: invalid input parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   bool loaded = false;
   if(ManualResetState)
   {
      LogEvent("STATE_RESET", Bid, 0.0, "manual reset on init");
   }
   else
   {
      loaded = LoadState();
   }

   ResetEffectiveParams();
   if(!loaded)
   {
      // 初回起動: この時点を RiskCapital の起点とする
      g_startAcctEquity = AccountEquity();
      g_peakVE          = RiskCapital;
      g_dayStartVE      = RiskCapital;
      g_dayKey          = JstDayKey();
      g_disabled        = false;
      g_sigHalt         = false;
   }
   // 日付が変わっていたら日次スナップショットを取り直す
   if(g_dayKey != JstDayKey())
   {
      g_dayKey     = JstDayKey();
      g_dayStartVE = VirtualEquity();
   }

   g_anchorLevel = LevelAtOrBelow(Bid);
   g_prevBid     = Bid;
   SaveState();

   LogEvent("INIT", Bid, 0.0,
            StringFormat("loaded=%d disabled=%d anchor=%.5f peak_ve=%.0f start_equity=%.0f signal=%d sig_halt=%d",
                         loaded ? 1 : 0, g_disabled ? 1 : 0,
                         g_anchorLevel, g_peakVE, g_startAcctEquity,
                         (UseSignal && SignalURL != "") ? 1 : 0, g_sigHalt ? 1 : 0));
   if(UseSignal && SignalURL == "")
      Print("NanbanGridEA: SignalURL is empty - signal link OFF (v0.1 behavior).");
   if(g_disabled)
      Print("NanbanGridEA: DISABLED by full stop. ",
            "Delete the state file or set ManualResetState=true once to re-enable.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   SaveState();
   LogEvent("DEINIT", Bid, 0.0, StringFormat("reason=%d", reason));
}

//+------------------------------------------------------------------+
//| メイン                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   if(g_disabled) return;                    // 全停止後は手動リセットまで動かない
   if(Bid <= 0.0 || Ask <= 0.0) return;

   double ve = VirtualEquity();

   //--- ピーク更新（永続化は最大1分に1回まで） ---
   if(ve > g_peakVE)
   {
      g_peakVE = ve;
      if(TimeCurrent() - g_lastStateSave >= 60) SaveState();
   }
   double ddPct = (g_peakVE - ve) / RiskCapital * 100.0;

   //--- 全停止: DDが FullStopDDPct に達したら全決済 + 無効化 ---
   if(ddPct >= g_effFullStopDDPct)
   {
      LogEvent("FULL_STOP", Bid, 0.0,
               StringFormat("dd=%.2f%% ve=%.0f peak=%.0f", ddPct, ve, g_peakVE));
      CloseAllOwn("FULL_STOP");
      g_disabled = true;
      SaveState();
      return;
   }

   //--- 日次ロールオーバー（JST日付が変わったらスナップショット更新） ---
   string today = JstDayKey();
   if(today != g_dayKey)
   {
      g_dayKey     = today;
      g_dayStartVE = ve;
      SaveState();
      LogEvent("DAY_ROLLOVER", Bid, 0.0,
               StringFormat("day=%s day_start_ve=%.0f", today, ve));
   }
   // 日次損失: 日初の仮想評価額スナップショットとの差で判定する（簡易法。
   // EAが止まっていた時間帯の変動は、再開後最初のティックの値で代用される）
   double dailyLossPct = (g_dayStartVE - ve) / RiskCapital * 100.0;

   //--- 信号連携: 定期取得とモード反映 ---
   bool sigEnabled = (UseSignal && SignalURL != "");
   bool sigBlockNew = false;
   bool sigExit     = false;
   if(sigEnabled)
   {
      if(TimeCurrent() - g_lastPoll >= SignalPollMinutes * 60)
         FetchSignal();

      // CLOSE_ALL: 二重確認（連続ポーリング）がそろったら全決済して停止
      if(g_sigMode == "CLOSE_ALL" && g_closeAllCount >= CloseAllConfirmPolls &&
         !g_sigHalt)
      {
         LogEvent("SIGNAL_CLOSE_ALL", Bid, 0.0,
                  StringFormat("confirmed=%d", g_closeAllCount));
         CloseAllOwn("SIGNAL_CLOSE_ALL");
         g_sigHalt = true;
         SaveState();
      }

      sigBlockNew = (g_sigMode == "CAUTION" || g_sigMode == "EXIT_ONLY" ||
                     g_sigMode == "CLOSE_ALL" || g_sigMode == "INVALID" ||
                     g_sigMode == "NONE"    || g_sigHalt);
      sigExit     = (g_sigMode == "EXIT_ONLY") ||
                    (g_sigMode == "INVALID" &&
                     SignalInvalidHours() >= SignalFailHoursToExit);
      if(sigExit && !g_exitApplied)
      {
         TightenTakeProfits();
         g_exitApplied = true;
      }
      LogFilterChange("SIGNAL", sigBlockNew, g_wasSigBlocked, Bid,
                      StringFormat("mode=%s", g_sigMode));
   }

   //--- 新規可否の判定 ---
   bool ddPaused      = (ddPct >= g_effPauseDDPct);
   bool dailyBlocked  = (dailyLossPct >= g_effDailyLossPct);
   bool timeBlocked   = TimeBlocks();
   bool trendBlocked  = !TrendAllows();
   bool spreadBlocked = (SpreadPips() > g_effMaxSpread);
   int  ownCount      = CountOwnPositions();
   bool maxPosReached = (ownCount >= g_effMaxPos);

   LogFilterChange("DD_PAUSE", ddPaused, g_wasDdPaused, Bid,
                   StringFormat("dd=%.2f%%", ddPct));
   LogFilterChange("DAILY_LOSS", dailyBlocked, g_wasDailyBlocked, Bid,
                   StringFormat("daily=%.2f%%", dailyLossPct));
   LogFilterChange("TIME", timeBlocked, g_wasTimeBlocked, Bid, "");
   LogFilterChange("TREND", trendBlocked, g_wasTrendBlocked, Bid,
                   StringFormat("bid=%.5f", Bid));
   LogFilterChange("SPREAD", spreadBlocked, g_wasSpreadBlocked, Bid,
                   StringFormat("spread=%.2fpips", SpreadPips()));
   LogFilterChange("MAXPOS", maxPosReached, g_wasMaxPosLogged, Bid,
                   StringFormat("count=%d", ownCount));

   bool canEnter = !(ddPaused || dailyBlocked || timeBlocked ||
                     trendBlocked || spreadBlocked || maxPosReached ||
                     sigBlockNew);

   //--- グリッド発注: 前ティックから「水準そのものを下抜けた」水準だけ処理 ---
   // v0.2.1: ループの下限は LevelAtOrBelow(Bid) ではなく Bid 自身。
   // ゾーンに入っただけでそのゾーンの下限水準を買うことをやめ、
   // バックテスト前提（水準を割ったときにその水準で買う）に一致させた。
   // フィルターで止まっている間も g_prevBid は更新する。
   // （＝ブロック中に通過した水準は「消費」され、解除後にまとめて買わない）
   if(g_prevBid > 0.0 && Bid < g_prevBid)
   {
      double lvl = LevelAtOrBelow(g_prevBid - 1e-7);
      int guard = 0;
      while(lvl >= Bid - 1e-7 && guard < 50)
      {
         if(canEnter && !LevelOccupied(lvl))
         {
            if(OpenBuy(lvl))
            {
               ownCount++;
               if(ownCount >= g_effMaxPos) canEnter = false;
            }
         }
         lvl = NormalizeDouble(lvl - g_effGridStep, 8);
         guard++;
      }
   }
   g_prevBid = Bid;
}
//+------------------------------------------------------------------+
