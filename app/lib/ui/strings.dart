import 'format.dart';
/// Every word the person reads, in one place (docs/UI.md). English only in version 1;
/// another language later means translating this file.
class S {
  S._();

  static const appName = 'teleBackup';

  // generic
  static const next = 'Next';
  static const back = 'Back';
  static const cancel = 'Cancel';
  static const save = 'Save';
  static const close = 'Close';
  static const tryAgain = 'Try again';
  static const retry = 'Retry';
  static const somethingWentWrong = 'Something went wrong. Try again.';
  static const loading = 'Loading';

  // welcome (O1)
  static const welcomeTitle = 'Free up your phone, keep every photo in your own Telegram.';
  static const welcomeBody =
      'teleBackup moves photos and videos from folders you pick into a private Telegram group that only you own. '
      'It can delete them from the phone once they are safely uploaded. You choose when.';
  static const welcomeTime = 'Setup takes about 10 minutes. You need the Telegram app on this phone.';
  static const startSetup = 'Start setup';

  // permissions (O2)
  static const permissionsTitle = 'Permissions';
  static const permNotifications = 'Notifications';
  static const permNotificationsWhy = 'To show backup progress.';
  static const permFiles = 'All files access';
  static const permFilesWhy =
      'To read your folders and delete files only after they are backed up. Android opens a settings page: turn on teleBackup there.';
  static const permBackground = 'Run in background';
  static const permBackgroundWhy =
      'So Android does not stop the backup. Pick "Allow" or "Don\'t optimise" on the next screen.';
  static const allow = 'Allow';
  static const openSettings = 'Open settings';
  static const makerLine = 'Your phone may also need Auto-start turned on.';
  static const makerHow = 'How';

  // bot (O3)
  static const botTitle = 'Create your bot';
  static const botIntro = 'A bot is a small Telegram helper that posts your photos. You make it yourself in 1 minute.';
  static const botStep1 = '1. Open @BotFather';
  static const botStep2 = '2. Send /newbot';
  static const botStep3 = '3. Pick any name, then a username ending in "bot"';
  static const botStep4 = '4. BotFather replies with a token. Copy it.';
  static const openTelegram = 'Open Telegram';
  static const botTokenLabel = 'Bot token';
  static const paste = 'Paste';
  static const tokenChecking = 'Checking...';
  static String tokenOk(String username) => 'Connected to @$username';
  static const tokenWrong = 'That token did not work. Copy it again from BotFather.';
  static const noInternet = 'No internet. Try again when online.';

  // group (O4)
  static const groupTitle = 'Make your private group';
  static const groupStep1 = '1. In Telegram, make a new group. Name it e.g. "My photos backup".';
  static const groupStep2 = '2. Group settings > turn on Topics.';
  static const groupStep3 = '3. Add your bot to the group, then make it an admin with "Manage topics" on.';
  static const groupStep4 = '4. Send any message in the group.';
  static const findGroup = 'Find my group';
  static const noGroupFound =
      'No group found yet. Make sure you added the bot and sent a message in the group in the last day. Then tap Find again.';
  static const checkTopicsOn = 'Topics on';
  static const checkBotAdmin = 'Bot is admin';
  static const checkBotTopics = 'Bot can manage topics';
  static const fixTopicsOff = 'Topics are off. Turn on Topics in the group settings, then tap Find again.';
  static const fixNotAdmin = 'The bot is not an admin. Make it an admin in the group, then tap Find again.';
  static const fixNoManageTopics = 'Turn on "Manage topics" for the bot, then tap Find again.';

  // account (O5)
  static const accountTitle = 'Big videos (50 MB and over)';
  static const accountBody =
      'Bots can only send files under 50 MB. For bigger videos, and for a stronger check before anything is deleted, '
      'teleBackup can use your own Telegram account.';
  static const recommended = 'Recommended.';
  static const loginToAccount = 'Log in to my account';
  static const skip = 'Skip';
  static const skipNote = 'Skip for now: big videos wait, and delete stays off until you log in.';

  // suggested rules (O6)
  static const suggestTitle = 'What to back up';
  static const suggestBody =
      'We found these folders on your phone. Each one gets its own topic. They all start in "upload only": nothing is deleted yet.';
  static const backUpFrom = 'Back up from:';
  static const fromToday = 'Today on';
  static const fromEverything = 'Everything';
  static const fromDate = 'Since a date...';
  static const createRules = 'Create rules';
  static const makingTopics = 'Making topics...';
  static const noFoldersFound = 'No camera or chat folders were found. You can add a folder yourself later.';

  // done (O7)
  static const doneTitle = 'You\'re set';
  static const doneBody = 'teleBackup scans once a day and uploads on Wi-Fi. You will see progress in the notification bar.';
  static const doneNothingDeleted = 'Nothing is deleted from your phone until you turn on delete for a rule.';
  static const goHome = 'Go to Home';
  static String stepOf(int n, int total) => 'Step $n of $total';

  // tabs
  static const tabHome = 'Home';
  static const tabRules = 'Rules';
  static const tabHistory = 'History';
  static const tabSettings = 'Settings';

  // home
  static const scanNow = 'Scan now';
  static const uploadNow = 'Upload now';
  static const pause = 'Pause';
  static const resume = 'Resume';
  static const resumeNow = 'Resume now';
  static const useMobileOnce = 'Use mobile data once';
  static const continueSetup = 'Continue setup';
  static const fix = 'Fix';
  static const logIn = 'Log in';
  static const review = 'Review';
  static const see = 'See';
  static const today = 'Today';
  static const uploaded = 'Uploaded';
  static const freed = 'Freed';
  static const inQueue = 'In queue';
  static const skipped = 'Skipped';
  static String freedSoFar(String size) => 'Freed so far: $size';
  static String lastScan(String when) => 'Last scan:  $when';
  static String lastUpload(String when) => 'Last upload: $when';

  // rules
  static const rulesTitle = 'Rules';
  static const addRule = 'Add a rule';
  static const rulesEmpty = 'No rules yet. A rule picks a folder and the topic it goes to.';
  static const ruleOffNote = 'Off. Nothing is scanned.';
  static const uploadOnly = 'Upload only';
  static String uploadAndDelete(int days) => 'Upload & delete · $days days';
  static const media = 'Media';
  static const originalFile = 'Original file';
  static String deletePaused(String reason) => 'Delete paused: $reason';

  // rule editor
  static const newRule = 'New rule';
  static const editRule = 'Edit rule';
  static const ruleName = 'Name';
  static const folder = 'Folder';
  static const includeSubfolders = 'Include folders inside it';
  static const sortDocuments = 'Put photos of documents in the Documents topic';
  static const sortDocumentsHelp = 'Photos of paper, bills, letters and ID cards go to the Documents topic, even from this folder. Videos are not checked. Off: everything stays in this folder\'s topic.';
  static const sortDocumentsNeedsTopic = 'Choose the Documents topic in Settings first.';
  static const sending = 'Sending';
  static const groupByDay = 'Group each day\'s photos';
  static const groupByDayHelp = 'Photos and videos from the same day are sent together, up to 10 in one album.';
  static const documentsTopic = 'Documents topic';
  static const documentsTopicNone = 'Not chosen';
  static const documentsTopicMake = 'Make a topic called Documents';
  static const documentsTopicOff = 'Turn off';
  static const documentsTopicHelp = 'Where photos of documents go, for the folders that have sorting turned on.';
  static const fileTypes = 'File types';
  static const photosAndVideos = 'Photos and videos';
  static const photosOnly = 'Photos';
  static const videosOnly = 'Videos';
  static const telegramTopic = 'Telegram topic';
  static const sendAs = 'Send as';
  static const sendAsMediaHelp = 'Media: looks nice in Telegram, but photos are made smaller.';
  static const sendAsOriginalHelp = 'Original file: exact copy, full quality, shows as a file.';
  static const afterUpload = 'After upload';
  static const keepOnPhone = 'Keep on phone (upload only)';
  static const deleteFromPhone = 'Delete from phone after';
  static const days = 'days';
  static const firstDeleteCheck = 'First delete needs your check';
  static const deleteThisRule = 'Delete this rule';
  static const pickFolder = 'Pick a folder.';
  static const nameUsed = 'This name is already used.';
  static String previewLine(int count, String size) =>
      count == 0 ? 'Nothing to add right now.' : 'This adds ${plural(count, 'file')} ($size), oldest first.';

  // dialogs
  static const deleteOnTitle = 'Delete from this phone?';
  static String deleteOnBody(int days) =>
      'After a file is uploaded and checked, teleBackup deletes it from this phone after $days days. Telegram will then have the only copy. '
      'If the Telegram group or account is lost, these files are gone. The first delete waits for you to check it.';
  static const deleteOnCheck = 'I understand Telegram keeps the only copy.';
  static const turnOnDelete = 'Turn on delete';
  static String removeRuleTitle(String name) => 'Delete rule "$name"?';
  static const removeRuleBody =
      'Files on the phone and in Telegram are not touched. Files waiting in the queue for this rule are dropped.';
  static const deleteRule = 'Delete rule';
  static const killTitle = 'Stop all deletes?';
  static const killBody = 'Every rule becomes upload only. You can turn delete back on per rule.';
  static const stopDeletes = 'Stop deletes';
  static const mobileTitle = 'Use mobile data?';
  static String mobileBody(int count, String size) => 'This uploads ${plural(count, 'file')} ($size) on mobile data.';
  static const mobileSettingTitle = 'Use mobile data for backups?';
  static const mobileSettingBody = 'Backups will run on any connection. Large videos can use a lot of data.';
  static const turnOn = 'Turn on';
  static const logoutTitle = 'Log out of Telegram account?';
  static const logoutBody = 'Videos of 50 MB and over will wait until you log in again.';
  static const logOut = 'Log out';
  static const changeGroupTitle = 'Change group?';
  static const changeTgBody =
      'Files already uploaded stay where they are. New uploads go to the new group. Topics will be made again.';
  static const change = 'Change';
  static const wipeTitle = 'Wipe all teleBackup data?';
  static const wipe = 'Wipe';

  // review
  static const reviewTitle = 'Check before deleting';
  static String reviewBody(int count) => 'These ${plural(count, 'file')} are backed up and checked in Telegram. teleBackup will delete them from this phone.';
  static String reviewTotal(String size) => 'Total: $size';
  static const reviewTap = 'Tap a photo to see it and its Telegram message.';
  static const notNow = 'Not now';
  static const looksRight = 'Looks right, delete';

  // history
  static const historyTitle = 'History';
  static const filterAll = 'All';
  static const filterUploaded = 'Uploaded';
  static const filterDeleted = 'Deleted';
  static const filterSkipped = 'Skipped';
  static const filterProblems = 'Problems';
  static const historyEmpty = 'Nothing yet. Uploads and deletes will show up here.';
  static const find = 'Find';

  // file
  static const openInTelegram = 'Open in Telegram';
  static const deletedFromPhone = 'Deleted from phone';
  static String checkCode(String code) => 'Check code: $code';

  // settings
  static const settingsTitle = 'Settings';
  static const network = 'Network';
  static const useMobileData = 'Use mobile data';
  static const mobileDataHelp = 'When off, uploads wait for Wi-Fi.';
  static const pauseButtons = 'Pause buttons';
  static const delayOptions = 'Delay options';
  static const newRules = 'New rules';
  static const keepAfterUpload = 'Keep on phone after upload';
  static const telegram = 'Telegram';
  static const botGroupAccount = 'Bot, group and account';
  static const phone = 'Phone';
  static const permissions = 'Permissions';
  static const backgroundRunning = 'Background running';
  static const safety = 'Safety';
  static const stopAllDeletes = 'Stop all deletes now';
  static const stopAllDeletesHelp = 'Turns every rule to upload only.';
  static const rulesSection = 'Rules';
  static const exportRules = 'Export rules';
  static const importRules = 'Import rules';
  static const help = 'Help';
  static const diagnostics = 'Diagnostics';
  static const setupAgain = 'Setup again';
  static const developer = 'Developer';

  // status card
  static const setupNotFinished = 'Setup not finished';
  static const finishSetupLine = 'Finish setup to start backing up.';
  static const backupStopped = 'Backup stopped';
  static const backingUp = 'Backing up';
  static const pausing = 'Pausing...';
  static const paused = 'Paused';
  static const checkingFolders = 'Checking folders';
  static const waitingForWifi = 'Waiting for Wi-Fi';
  static const doneForToday = 'Done for today';
  static const doneForTodayLine = 'Android limits background work. Continues in a few hours.';
  static const allBackedUp = 'All backed up';
  static const nextCheckTonight = 'Next check tonight.';
  static const resumesByItself = 'Resumes by itself.';

  // telegram screens
  static const tgTitle = 'Telegram connection';
  static const checkAgain = 'Check again';
  static const changeBot = 'Change bot';
  static const changeGroup = 'Change group';
  static const loginTitle = 'Log in to your account';

  // diagnostics
  static const copy = 'Copy';
  static const share = 'Share';
  static const diagHeader = 'No passwords, tokens or phone numbers are included.';
}
