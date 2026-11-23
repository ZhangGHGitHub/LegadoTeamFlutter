delete from files where _data like '/storage/emulated/0/Download/saf_%';
delete from downloads where _data like '/storage/emulated/0/Download/saf_%';
select count(*) from files where _data like '/storage/emulated/0/Download/saf_%';
