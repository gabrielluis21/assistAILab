import { runDemoSeed } from './demo_seed.js';

runDemoSeed().then(result => {
  console.log('FE-02B: dataset fictício criado/retomado e projeções verificadas.');
  console.table(result.accounts);
  console.table(result.orders);
  console.log('Senha inicial: SEED_DEMO_PASSWORD ou Demo@123456. Reexecutar não redefine senhas nem edições manuais.');
  console.log('Frontend: conectar ao backend usando assistailab_fe02b_demo; cada sessão deve executar seu próprio bootstrap v2. Preservar a Outbox.');
}).catch(error => {
  console.error('Seed FE-02B interrompido:', error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
