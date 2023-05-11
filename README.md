# TiP-project-VPP

## Opis

Celem projektu jest zapoznanie się z technologią VPP. Składają się na to następujące elementy:
- Stworzenie referatu obrazującego zastosowanie VPP w technologiach telekomunikacyjnych (link wkrótce)
- Utworzenie Proof of Concept z zainstalowanym VPP
- Utworzenie Proof of Concept z zainstalowanym VPP w środowisku z kontenerami

## Link do referatu

https://www.overleaf.com/project/6458ec6edbbbbb551fe21368

## Proof of Concept

### Opis
Proof of concept (Przykładowa aplikacja) składa się z dwóch kontenerów, które przesyłają między sobą duże ilości danych za pomocą programu [iperf](https://iperf.fr/), który służy do testowania przepustowości łącza. Na jednym z kontenerów (na serwerze) jest zainstalowany program [snort](https://www.snort.org/), którego zadaniem jest zinterpretować powstały ruch jako potencjalny atak DoS i wypisać ostrzeżenie o jego wystąpieniu.

### Instalacja VPP

Ruch sieciowy w przykładowej aplikacji odbywa się poprzez VPP zainstalowane na hoście, na którym działają kontenery. W celu przetestowania aplikacji, należy go najpierw zainstalować.

```
curl −s https://packagecloud.io/install/repositories/fdio/release/script.deb.sh | sudo bash
sudo apt-get update
sudo apt−get install vpp vpp−plugin−core vpp−plugin−dpdk
```

Do uruchomienia przykładowej aplikacji, wymagane jest posiadanie zainstalowanego dockera

### Instalacja

```
git clone git@github.com:ChrisGadek1/TiP-project-VPP.git
cd TiP-project-VPP/poc/vpp/src/
```
### Uruchomienie

```
sudo make docker
sudo make start
```

### Zaobserwowane działanie

Aby podejrzeć działanie aplikacji, wystarczy sprawdzić dockerowe logi na kontenerze serwera

```
sudo docker logs server
```

Większość logów dotyczy uruchomienia i zwalidowania programu [snort](https://www.snort.org/). Dalej widać logi pokazujące uruchomienie programu [iperf](https://iperf.fr/) i, co za tym idzie, rozpoczęcie masowego przesyłania pakietów

```
Commencing packet processing (pid=106)
```

Po chwili zauważamy ostrzeżenie wypisane przez program snort

```
05/11-14:29:22.470638  [**] [1:10000001:0] Possible DoS - other TCP [**] [Priority: 0] {TCP} 169.254.12.1:38602 -> 169.254.12.2:5001
```

Został on skonfiguwany tak, aby wypisał ostrzeżenie przy zajściu odpowiednich warunków w systemie. Warunki te opisują reguły załadowane do programu, a kluczowa reguła wykrywająca atak ma następującą strukturę:

```
alert tcp !$HOME_NET any -> $HOME_NET any (msg:"Possible DoS - other TCP"; flow: stateless; detection_filter: track by_src, count 1000, seconds 3; sid:10000001)
```

Zatem uruchomi ona alarm, gdy otrzyma więcej niż 1000 pakietów do przetworzenia w ciągu 3 sekund.
