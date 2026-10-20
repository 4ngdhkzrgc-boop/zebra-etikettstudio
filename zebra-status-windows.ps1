# Zebra Etikettstudio – lokal Windows-hjelper for status ved utskrift
# Krever ikke administratorrettigheter. Kjor pa PC i bedriftens skrivernett.
# Holder en HTTP-tjeneste KUN pa 127.0.0.1:37371 mens dette vinduet er apent.
$ErrorActionPreference='Stop'
$origin='https://4ngdhkzrgc-boop.github.io'
$crlf=[string][char]13+[char]10
function Printer-Connect([string]$ip){
  $c=New-Object Net.Sockets.TcpClient
  $async=$null
  try{
    $async=$c.BeginConnect($ip,9100,$null,$null)
    if(-not $async.AsyncWaitHandle.WaitOne(1800)){throw 'Port 9100 svarer ikke'}
    $c.EndConnect($async)
    $c.SendTimeout=3000;$c.ReceiveTimeout=1100
    return $c
  }catch{$c.Close();throw}finally{if($async){$async.AsyncWaitHandle.Close()}}
}
function Printer-Var([string]$ip,[string]$key){
  $c=$null
  try{
    $c=Printer-Connect $ip
    $st=$c.GetStream()
    $b=[Text.Encoding]::ASCII.GetBytes('! U1 getvar "'+$key+'"'+$crlf)
    $st.Write($b,0,$b.Length)
    $reply=New-Object 'System.Collections.Generic.List[byte]'
    $deadline=[DateTime]::UtcNow.AddMilliseconds(950)
    $last=[DateTime]::UtcNow
    $buf=New-Object byte[] 512
    while([DateTime]::UtcNow -lt $deadline){
      if($st.DataAvailable){
        $n=$st.Read($buf,0,$buf.Length)
        if($n -le 0){break}
        for($i=0;$i -lt $n;$i++){$reply.Add($buf[$i])}
        $last=[DateTime]::UtcNow
        if($reply.Contains([byte]10)){break}
      }else{
        if($reply.Count -gt 0 -and ([DateTime]::UtcNow-$last).TotalMilliseconds -gt 130){break}
        Start-Sleep -Milliseconds 30
      }
    }
    return [Text.Encoding]::ASCII.GetString($reply.ToArray()).Trim().Trim('"')
  }catch{return ''}finally{if($c){$c.Close()}}
}
function Counter([string]$ip){
  $value=Printer-Var $ip 'odometer.total_label_count'
  if($value -match '^\d+$'){return [long]$value}
  return $null
}
function Printer-Error([string]$ip){
  $v=(Printer-Var $ip 'zpl.system_status').Replace('"','').Split(',')
  if($v.Length -ge 2){
    if($v[0] -eq '1'){return 'Skriveren er pauset'}
    if($v[1] -eq '1'){return 'Skriveren melder feil (papir, hode eller annet)'}
  }
  return ''
}
function Print-Checked([string]$ip,[byte[]]$zpl){
  $err=Printer-Error $ip
  if($err){return @{state='error';message=$err}}
  $before=Counter $ip
  $client=$null
  try{
    $client=Printer-Connect $ip
    $st=$client.GetStream()
    $st.Write($zpl,0,$zpl.Length)
    $st.Flush()
  }catch{return @{state='error';message=('Kunne ikke sende ZPL: '+$_.Exception.Message)}}
  finally{if($client){$client.Close()}}
  if($null -eq $before){return @{state='sent';message='Jobb sendt, men Zebra-telleren er utilgjengelig. Ingen bekreftelse.'}}
  $deadline=[DateTime]::UtcNow.AddSeconds(11)
  while([DateTime]::UtcNow -lt $deadline){
    Start-Sleep -Milliseconds 350
    $after=Counter $ip
    if($null -ne $after -and $after -gt $before){
      $count=$after-$before
      return @{state='confirmed';message="Zebra-telleren okte med $count etikett(er) etter jobben. Utskrift sannsynlig gjennomfort."}
    }
    $err=Printer-Error $ip
    if($err){return @{state='error';message=('Sendt, men skriverfeil: '+$err)}}
  }
  return @{state='sent';message='Jobb sendt, men etikettelleren okte ikke innen 11 sekunder. Ikke bekreftet.'}
}
# Batch-utskrift: kontroller og send til flere skrivere i samme operasjon.
# Hver skriver faar sin egen ZPL med riktig DPI/storrelse og ^PQ.
function Print-Batch($jobs){
  $items=New-Object System.Collections.ArrayList
  $seen=@{}
  $list=@($jobs)
  if($list.Count -lt 1 -or $list.Count -gt 31){throw 'Velg mellom 1 og 31 skrivere'}
  foreach($job in $list){
    $ip=[string]$job.ip
    if($ip -notmatch '^172[.]30[.]99[.](\d{1,3})$'){throw 'IP utenfor godkjent nettverk'}
    $last=[int]$Matches[1]
    if($last -lt 1 -or $last -gt 254){throw 'Ugyldig IP'}
    if($seen.ContainsKey($ip)){throw 'Duplikat IP i jobb'}
    $seen[$ip]=$true
    $zpl=[string]$job.zpl
    if(-not $zpl.StartsWith('^XA') -or -not $zpl.Contains('^XZ')){throw 'Ugyldig ZPL'}
    $bytes=[Text.Encoding]::UTF8.GetBytes($zpl)
    if($bytes.Length -gt 5000000){throw 'En etikett er for stor'}
    $errorText=Printer-Error $ip
    $before=if($errorText){$null}else{Counter $ip}
    [void]$items.Add(@{ip=$ip;zpl=$bytes;before=$before;error=$errorText;state='waiting';message='Venter'})
  }
  # Alle jobber sendes foer vi venter paa status, for aa unngaa serielle status-ventetider.
  foreach($item in $items){
    if($item.error){$item.state='error';$item.message=$item.error;continue}
    $c=$null
    try{
      $c=Printer-Connect $item.ip
      $st=$c.GetStream()
      $st.Write($item.zpl,0,$item.zpl.Length)
      $st.Flush()
      $item.state='sent';$item.message='ZPL sendt; avventer Zebra-status'
    }catch{
      $item.state='error';$item.message='Kunne ikke sende: '+$_.Exception.Message
    }finally{if($c){$c.Close()}}
  }
  $deadline=[DateTime]::UtcNow.AddSeconds(13)
  while([DateTime]::UtcNow -lt $deadline){
    $pending=@($items|Where-Object {$_.state -eq 'sent' -and $null -ne $_.before})
    if($pending.Count -eq 0){break}
    foreach($item in $pending){
      $after=Counter $item.ip
      if($null -ne $after -and $after -gt $item.before){
        $item.state='confirmed'
        $item.message='Etiketttelleren oekte etter utskrift (sannsynlig gjennomfoert)'
      }else{
        $errorText=Printer-Error $item.ip
        if($errorText){$item.state='error';$item.message=$errorText}
      }
      if([DateTime]::UtcNow -ge $deadline){break}
    }
    Start-Sleep -Milliseconds 150
  }
  $out=@()
  foreach($item in $items){
    if($item.state -eq 'sent'){$item.message='ZPL sendt, men ikke bekreftet av etikettelleren'}
    $out+=@{ip=$item.ip;state=$item.state;message=$item.message}
  }
  return @{results=$out}
}
function Receive-Http($stream){
  $head=New-Object 'System.Collections.Generic.List[byte]'
  $b=New-Object byte[] 1
  while($head.Count -lt 16384){
    if($stream.Read($b,0,1) -ne 1){throw 'Foresporsel avbrutt'}
    $head.Add($b[0]);$n=$head.Count
    if($n -ge 4 -and $head[$n-4] -eq 13 -and $head[$n-3] -eq 10 -and $head[$n-2] -eq 13 -and $head[$n-1] -eq 10){break}
  }
  if($head.Count -ge 16384){throw 'For lange headere'}
  $lines=[Text.Encoding]::ASCII.GetString($head.ToArray()) -split '\r\n'
  $first=$lines[0].Split(' ')
  if($first.Length -lt 2){throw 'Ugyldig HTTP'}
  $headers=@{}
  foreach($line in $lines){$i=$line.IndexOf(':');if($i -gt 0){$headers[$line.Substring(0,$i).ToLowerInvariant()]=$line.Substring($i+1).Trim()}}
  $len=0
  if($headers.ContainsKey('content-length')){
    if(-not [int]::TryParse($headers['content-length'],[ref]$len)){throw 'Ugyldig lengde'}
  }
  if($len -lt 0 -or $len -gt 48000000){throw 'Utskriftsdata er for stor'}
  $data=New-Object byte[] $len
  $pos=0
  while($pos -lt $len){
    $n=$stream.Read($data,$pos,$len-$pos)
    if($n -le 0){throw 'ZPL avbrutt'}
    $pos+=$n
  }
  return @{method=$first[0];path=$first[1];headers=$headers;body=$data}
}
function Respond($stream,[int]$status,$obj,[bool]$allow){
  $response=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $obj -Compress))
  $label=if($status -eq 200){'OK'}elseif($status -eq 403){'Forbidden'}else{'Bad Request'}
  $fields=@("HTTP/1.1 $status $label","Content-Type: application/json; charset=utf-8","Content-Length: $($response.Length)",'Connection: close')
  if($allow){
    $fields+=@("Access-Control-Allow-Origin: $origin",'Access-Control-Allow-Headers: Content-Type','Access-Control-Allow-Methods: GET, POST, OPTIONS','Access-Control-Allow-Private-Network: true','Access-Control-Allow-Local-Network: true')
  }
  $header=[Text.Encoding]::ASCII.GetBytes(($fields -join $crlf)+$crlf+$crlf)
  $stream.Write($header,0,$header.Length)
  $stream.Write($response,0,$response.Length)
  $stream.Flush()
}
try{
  $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,37371)
  $listener.Start()
}catch{Write-Host ('Kan ikke starte status-hjelper: '+$_.Exception.Message) -ForegroundColor Red;exit 1}
Write-Host 'Zebra-status er klar. Apne Etikettstudio i Chrome pa denne PC-en.' -ForegroundColor Green
Write-Host 'Bare 127.0.0.1:37371 er apen. Trykk Ctrl+C for a stoppe.'
try{
  while($true){
    $client=$null
    try{
      $client=$listener.AcceptTcpClient()
      $client.ReceiveTimeout=120000;$client.SendTimeout=120000
      $stream=$client.GetStream()
      $req=Receive-Http $stream
      $allowed=([string]$req.headers['origin'] -ceq $origin)
      if(-not $allowed){Respond $stream 403 @{state='error';message='Ikke tillatt nettside'} $false;continue}
      if($req.method -eq 'OPTIONS'){Respond $stream 200 @{ok=$true} $true;continue}
      if($req.method -eq 'GET' -and $req.path -eq '/health'){Respond $stream 200 @{ok=$true;version=2;batch=$true} $true;continue}
      if($req.method -eq 'POST' -and $req.path -eq '/batch'){
        try{
          $json=[Text.Encoding]::UTF8.GetString($req.body)
          $payload=ConvertFrom-Json -InputObject $json
          if(-not $payload.jobs){throw 'Ingen skriverjobber mottatt'}
          $result=Print-Batch $payload.jobs
          Respond $stream 200 $result $true
        }catch{
          Respond $stream 400 @{state='error';message=('Batch-feil: '+$_.Exception.Message)} $true
        }
        continue
      }
      if($req.method -eq 'POST' -and $req.path -match '^/print\?ip=(172\.30\.99\.(\d{1,3}))
        $ip=$matches[1];$last=[int]$matches[2]
        if($last -lt 1 -or $last -gt 254){Respond $stream 400 @{state='error';message='Ugyldig IP'} $true;continue}
        if($req.body.Length -lt 1){Respond $stream 400 @{state='error';message='Tom ZPL'} $true;continue}
        Write-Host ('Sender til '+$ip)
        $result=Print-Checked $ip $req.body
        Write-Host $result.message
        Respond $stream 200 $result $true
        continue
      }
      Respond $stream 400 @{state='error';message='Ukjent foresporsel'} $true
    }catch{Write-Host ('Feil: '+$_.Exception.Message) -ForegroundColor Yellow}
    finally{if($client){$client.Close()}}
  }
}finally{$listener.Stop()}){
        $ip=$matches[1];$last=[int]$matches[2]
        if($last -lt 1 -or $last -gt 254){Respond $stream 400 @{state='error';message='Ugyldig IP'} $true;continue}
        if($req.body.Length -lt 1){Respond $stream 400 @{state='error';message='Tom ZPL'} $true;continue}
        Write-Host ('Sender til '+$ip)
        $result=Print-Checked $ip $req.body
        Write-Host $result.message
        Respond $stream 200 $result $true
        continue
      }
      Respond $stream 400 @{state='error';message='Ukjent foresporsel'} $true
    }catch{Write-Host ('Feil: '+$_.Exception.Message) -ForegroundColor Yellow}
    finally{if($client){$client.Close()}}
  }
}finally{$listener.Stop()}