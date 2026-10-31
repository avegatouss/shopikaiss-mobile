import json, sqlite3, subprocess, tempfile, time, pathlib, queue, threading, statistics
root = pathlib.Path(__file__).resolve().parents[2]
exe = root/'build/windows-moteur/bundle/bin/shopikaiss_moteur.exe'
folder = pathlib.Path(tempfile.mkdtemp(prefix='shopikaiss-benchmark-synthetic-'))
subprocess.run([str(exe),'--dossier',str(folder)], input='', text=True, capture_output=True, timeout=20, check=True)
db=sqlite3.connect(folder/'caisse.db')
device={'uuid':'44444444-4444-4444-8444-444444444444','terminal_uuid':'55555555-5555-4555-8555-555555555555','boutique_uuid':'66666666-6666-4666-8666-666666666666','nom':'BENCHMARK','terminal_nom':'SYNTHESE'}
for k,v in {'v2.origine':'https://benchmark.invalid','v2.appareil':json.dumps(device),'v2.curseur':'synthetic','v2.epoque':'1','v2.catalogue_le':'2026-10-31T00:00:00Z'}.items():
 db.execute('INSERT OR REPLACE INTO kv(cle,valeur) VALUES (?,?)',(k,v))
def entity(kind,key,data): db.execute('INSERT INTO v2_entites(type,cle,revision,donnees) VALUES (?,?,?,?)',(kind,key,'1',json.dumps(data)))
for n in range(5000):
 uid=f'11111111-1111-4111-8111-{n:012d}'
 entity('produit',uid,{'nom':f'Produit {n:04d}','reference':f'P{n}','categorie':'Test','prix':500,'stock_illimite':False,'actif':True,'vente_locale':True})
 entity('stock.projection',uid,{'produit_uuid':uid,'lot_uuid':None,'quantite':'100.000000'})
 entity('code_barre',f'619{n:010d}',{'code':f'619{n:010d}','produit_uuid':uid,'conditionnement_uuid':None})
db.commit(); db.close()
p=subprocess.Popen([str(exe),'--dossier',str(folder)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf-8')
q=queue.Queue()
def read():
 for line in p.stdout: q.put(json.loads(line))
threading.Thread(target=read,daemon=True).start()
seq=0
def call(cmd,args={}):
 global seq
 seq+=1; ident=str(seq); started=time.perf_counter()
 p.stdin.write(json.dumps({'version':1,'kind':'request','id':ident,'command':cmd,'arguments':args})+'\n'); p.stdin.flush()
 while True:
  r=q.get(timeout=30)
  if r.get('id')==ident:
   if not r.get('ok'): raise RuntimeError(r.get('error'))
   return (time.perf_counter()-started)*1000,r['result']
try:
 cold,view=call('view')
 assert view['products_total']==5000,view.get('products_total')
 results={'products':5000,'cold_start_and_first_view_ms':round(cold,2)}
 for cmd,args in [('view',{}),('search',{'query':'Produit'}),('scan',{'code':'6190000000001'})]:
  values=[call(cmd,args)[0] for _ in range(20)]
  results[cmd]={'median_ms':round(statistics.median(values),2),'max_ms':round(max(values),2)}
 print(json.dumps(results,indent=2))
 (root/'build/benchmark-release-result.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
finally:
 p.stdin.close()
 try: p.wait(timeout=10)
 except subprocess.TimeoutExpired: p.kill(); p.wait()
