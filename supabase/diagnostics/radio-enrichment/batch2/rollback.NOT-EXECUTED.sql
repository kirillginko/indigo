-- NOT EXECUTED. Exact batch-owned primary keys only; portrait trigger rechecks identity.
begin;
delete from external_ids e using (values ('b9ef79da-9170-58fb-a2a4-f9a775630fd5'::uuid,'fcc75b03-80c1-49cc-b675-eb6ac916d3b0'::uuid,'4304488','https://musicbrainz.org/artist/54492185-df45-494f-b133-f52da3fba781'),
('314cd4d6-d9a2-5335-b8c0-5acd53f7d111'::uuid,'cc49be7c-cd9b-4eaa-88a2-06f3f202c6c4'::uuid,'8270419','https://musicbrainz.org/artist/46a4b150-be30-44b3-a337-e06a72657d33'),
('5b70de5f-4f5f-57d4-b742-a60073b7a20c'::uuid,'9dbaa8ab-bef4-4690-9d1e-0f2e64f5a483'::uuid,'8722','https://musicbrainz.org/artist/806b793c-fb2c-401e-be44-f753c0ea2f15'),
('c8ad0aa9-8360-5688-ba6d-684237084cd5'::uuid,'d1ba9a33-dee7-41f0-85a6-f8e87bf7c8c7'::uuid,'1622339','https://musicbrainz.org/artist/c27d4389-390e-497c-9a41-dd446ace742c'),
('64d807e0-1460-51ba-a492-2d1665f19e8c'::uuid,'d3739140-435f-43da-8bd1-24e92aff6c70'::uuid,'29966','https://musicbrainz.org/artist/1dbdc230-fe9c-4d71-b72e-88ba98800167'),
('ceffa617-3c98-568d-aed8-45b842987c2d'::uuid,'8941dae6-4879-46d8-bf42-721166f7880a'::uuid,'20560','https://musicbrainz.org/artist/826b488f-5164-45ca-abc4-ab11b3c321eb'),
('8823b2f1-a42e-53e1-af9a-dc01cc897804'::uuid,'2c8e9ead-44b9-4482-b1a6-814480c33074'::uuid,'55738','https://musicbrainz.org/artist/fe19b809-e86c-4736-882a-53b72e23171b'),
('79ae0551-d1d6-5a8a-b0dc-4632de999ab5'::uuid,'46812b32-b9b5-48a9-9905-f79cd8b4cf44'::uuid,'866','https://musicbrainz.org/artist/07065c90-1519-4bd9-8259-9872f3c9a776'),
('2c0eacd8-7262-50ec-9f7e-aff57c98b5c8'::uuid,'3bc0ad49-5d5a-495f-8189-04425126743a'::uuid,'534','https://musicbrainz.org/artist/cedf92fe-eba1-45e2-ba16-b1b6af5169b8'),
('96878b94-a2ae-525a-9a37-95972de62a05'::uuid,'fd2407d9-32b9-4184-9476-c6f5f66a48ea'::uuid,'44126','https://musicbrainz.org/artist/bc16d640-a069-42ec-a8c1-c24fd5c3d206'),
('d35edd65-c65a-5e0e-85a2-d2ca721ce25d'::uuid,'464eeab3-e2ff-4dff-a7ec-6b499b6b88fe'::uuid,'270578','https://musicbrainz.org/artist/ca5db97b-ba17-4e85-a876-46065e2052b3'),
('2ccc0f64-be0b-5df5-8013-58e4013519b6'::uuid,'a2d05287-c666-46ef-8a60-57c750e1596d'::uuid,'48720','https://musicbrainz.org/artist/91cfbe94-7fc3-4bcc-9d95-767d87ac2ae5'),
('a2c51a72-5461-581a-bdba-23c7c390b599'::uuid,'515ee18c-571b-403f-a371-d359c2c4c4a8'::uuid,'1029','https://musicbrainz.org/artist/979d10bc-d1b9-41b1-8a87-7a7c68cbd885'),
('11054b4d-813e-5d8b-ba64-ca96ebe823bf'::uuid,'16806488-f939-4cac-bc1f-56987318badf'::uuid,'41249','https://musicbrainz.org/artist/f9ba6d40-60f3-4c85-ac23-0bf67c3247e4'),
('ae64a48a-de42-5c7a-94b3-a8173ab44950'::uuid,'d362f060-be2a-4e38-9f6e-0202df4b90b3'::uuid,'3563778','https://musicbrainz.org/artist/a3e77268-597b-4ce8-8837-78b673e20114'),
('3baa9d97-db4c-5cd7-b5cd-31aa64ed8ab5'::uuid,'1d2e7ab4-f4e1-4cc2-81ba-5ab92941d37c'::uuid,'59249','https://musicbrainz.org/artist/fd1a2d9d-9bb6-44de-83a3-41560658aba9'),
('747cc620-c7d8-53bc-86dd-48aaa79806d3'::uuid,'a750aa2f-956a-4dd4-ac68-0746c7f2e09f'::uuid,'36860','https://musicbrainz.org/artist/186edc09-db32-4d4f-ba71-eed418630c83'),
('f72fbe6c-590b-5368-8edd-184d6820b553'::uuid,'c5582c58-475c-4778-9af7-5c061fe4a87e'::uuid,'97988','https://musicbrainz.org/artist/9f7483cf-d8aa-45ce-b90c-da2e359a7815'),
('67ffe7e9-a036-560b-bc70-6bc44bf75ff3'::uuid,'f9250721-b691-4571-8ef5-4cdf3165bcd1'::uuid,'1300441','https://musicbrainz.org/artist/987fc4c9-2c99-4f6c-949b-8da8019769a8'),
('3f09fe5e-0b09-593e-a8ff-c931f7e39688'::uuid,'3d117c1a-850d-4577-b432-abae11642042'::uuid,'269','https://musicbrainz.org/artist/4d86ad4e-28d8-4e9f-8cf4-735c57060fdc'),
('fa64ff85-41f7-5dbd-9c6a-7a5825605cd2'::uuid,'6ab1be02-3723-4082-89f3-fd82e9ec2a69'::uuid,'98545','https://musicbrainz.org/artist/39515237-2d70-436a-800c-fcbac974bec4')) x(id,entity_id,external_id,source_url)
where e.id=x.id and e.entity_id=x.entity_id and e.entity_type='artist'
and e.provider='musicbrainz_discogs' and e.external_id=x.external_id and e.source_url=x.source_url;
commit;
