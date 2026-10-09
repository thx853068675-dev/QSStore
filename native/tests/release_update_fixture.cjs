const { loadEts } = require('./load_ets.cjs');
const jobs = loadEts('jobs/InstallJob');
function releaseUpdate(stages = jobs.InstallStage) {
  return loadEts('jobs/ReleaseUpdate', {
    '../data/DisplayVersion': loadEts('data/DisplayVersion'),
    '../data/ReleaseInfo': loadEts('data/ReleaseInfo'),
    './InstallJob': { ...jobs, InstallStage: stages }
  }).ReleaseUpdate;
}
module.exports = { releaseUpdate };
